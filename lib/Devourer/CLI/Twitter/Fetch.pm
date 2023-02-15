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
use Net::Statsd;

has nproc => (is => 'ro', default => sub { chomp(my $nproc = `nproc --all`); $nproc });
has logger => (is => 'ro', default => sub {
    return Log::Dispatch->new(
        outputs => [['Screen', min_level => 'info', newline => 1]]
    );
});
has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0] });
has http => (is => 'ro', default => sub { Furl->new(); });
has twitter_primary => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    return Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        ($self->settings->{twitter}{primary_credentials}{use_v2_api} ? (api_version => "2") : ()),
        ($self->settings->{twitter}{primary_credentials}{use_v2_api} ? (api_ext => "") : ()),
        consumer_key        => $self->settings->{twitter}{primary_credentials}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{primary_credentials}{consumer_secret},
        access_token        => $self->settings->{twitter}{primary_credentials}{access_token},
        access_token_secret => $self->settings->{twitter}{primary_credentials}{access_token_secret},
    );
});
has twitter_secondary => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    if (
        (
            $self->settings->{twitter}{primary_credentials}{consumer_key}        eq $self->settings->{twitter}{secondary_credentials}{consumer_key}    and
            $self->settings->{twitter}{primary_credentials}{consumer_secret}     eq $self->settings->{twitter}{secondary_credentials}{consumer_secret} and
            $self->settings->{twitter}{primary_credentials}{access_token}        eq $self->settings->{twitter}{secondary_credentials}{access_token}    and
            $self->settings->{twitter}{primary_credentials}{access_token_secret} eq $self->settings->{twitter}{secondary_credentials}{access_token_secret}
        ) or !$self->settings->{twitter}{secondary_credentials}
    ) {
        return $self->twitter_primary;
    }
    return Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        ($self->settings->{twitter}{secondary_credentials}{use_v2_api} ? (api_version => "2") : ()),
        ($self->settings->{twitter}{secondary_credentials}{use_v2_api} ? (api_ext => "") : ()),
        consumer_key        => $self->settings->{twitter}{secondary_credentials}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{secondary_credentials}{consumer_secret},
        access_token        => $self->settings->{twitter}{secondary_credentials}{access_token},
        access_token_secret => $self->settings->{twitter}{secondary_credentials}{access_token_secret},
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
has redownload_list => (is => 'ro', default => sub {
    my $redis = Redis->new(server => 'redis:6379');
    $redis->select(3);
    return $redis;
});
has opts => (is => 'ro', default => sub {
    return Getopt::Compact->new(
        name => 'devourer fetch twitter',
        struct => [
            [[qw(init)], qq(Initialize Redis DB)],
            [[qw(statsd)], qq(Send run duration metric as StatsD)],
            [[qw(statsd-host)], qq(Specify StatsD host address), ':s'],
            [[qw(statsd-port)], qq(Specify StatsD port), ':s'],
        ]
    )->opts;
});
has start_time => (is => 'ro', default => sub { localtime });
has finish_time => (is => 'ro', lazy => 1, default => sub { localtime });

sub run {
    my $self = shift;

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

    $self->logger->info('List members statuses fetching started!');

    for my $list_id (@{ $self->settings->{lists} }) {
        my $list_name = $self->_get_list_name($list_id);
        my $total_list_members = 0;
        my $list_pagination_token;
        while (1) {
            (my $list_members_id, $list_pagination_token) = eval { $self->_get_list_members_id($list_id, $list_pagination_token) };
            last if $@ or !defined($list_members_id);
            my $list_members_num = scalar(@$list_members_id);
            $total_list_members += $list_members_num;
            $self->logger->info("Total $total_list_members members fetching from list $list_id ($list_name)");
            my $tweets = $self->_get_user_timelines($list_members_id);
            my $media_urls = $self->_extract_file_name_and_url($tweets);
            $self->_download($media_urls);
            for (@$list_members_id) {
                $self->stored_list_members->set($_, 1) unless $self->stored_list_members->get($_);
            }
        }
        $self->logger->info("Total $total_list_members members fetched from list $list_id ($list_name)");
    }

    $self->logger->info('List members statuses fetching done!');

    $self->logger->info('Mediators statuses fetching started!');

    my $mediators = clone($self->settings->{mediators});
    while (my $mediators_slice = [splice @$mediators, 0, $self->nproc]) {
        my $favs = $self->_get_users_favorites($mediators_slice);
        my $tweets = $self->_get_user_timelines($mediators_slice);
        push(@{ $tweets->{referenced_tweets} }, @{ $favs->{referenced_tweets} }) if $tweets->{referenced_tweets} and $favs->{referenced_tweets};
        push(@{ $tweets->{tweets} }, @{ $favs->{tweets} }) if $tweets->{tweets} and $favs->{tweets};
        push(@{ $tweets->{users}  }, @{ $favs->{users} })  if $tweets->{users}  and $favs->{users};;
        push(@{ $tweets->{media}  }, @{ $favs->{media} })  if $tweets->{media}  and $favs->{media};;
        my $media_urls = $self->_extract_file_name_and_url($tweets);
        $self->_download($media_urls);
        last unless @$mediators;
    }

    $self->logger->info('Mediators favorites fetching done!');

    if ($self->opts->{statsd}) {
        $Net::Statsd::HOST = $self->opts->{'statsd-host'} // '127.0.0.1';
        $NET::Statsd::PORT = $self->opts->{'statsd-port'} // 8125;
        Net::Statsd::gauge(
            'devourer_twitter_fetch_duration',
            $self->finish_time->epoch - $self->start_time->epoch
        );
    }

    $self->logger->info('All done... I ate too much, I\'m full. :yum:');
}

sub _v2_shaping {
    my ($self, $tweets) = @_;

    my $ret = {};
    for my $tweet (@$tweets) {
        # v2 tweet
        my $shaped_data = {};
        if ($tweet->{retweeted_status}) {
            $shaped_data->{author_id} = $tweet->{retweeted_status}{user}{id_str};
            $shaped_data->{id} = $tweet->{retweeted_status}{id_str};
        } else {
            $shaped_data->{author_id} = $tweet->{user}{id_str};
            $shaped_data->{id} = $tweet->{id_str};
        }
        if ($tweet->{extended_entities}{media}) {
            for my $media (@{ $tweet->{extended_entities}{media} }) {
                push(@{ $shaped_data->{attachments}{media_keys} }, $media->{id_str});
            }
        }
        push(@{ $ret->{data} }, $shaped_data);

        # v2 referenced_tweet
        my $shaped_tweet = {};
        if ($tweet->{retweeted_status}) {
            $shaped_tweet->{author_id} = $tweet->{retweeted_status}{user}{id_str};
            $shaped_tweet->{id} = $tweet->{retweeted_status}{id_str};
            if ($tweet->{extended_entities}{media}) {
                for my $media (@{ $tweet->{extended_entities}{media} }) {
                    push(@{ $shaped_tweet->{attachments}{media_keys} }, $media->{id_str});
                }
            }
            push(@{ $ret->{includes}{tweets} }, $shaped_tweet);
        }

        # v2 user
        my $shaped_user = {};
        if ($tweet->{retweeted_status}) {
            $shaped_user->{id} = $tweet->{retweeted_status}{user}{id_str};
            $shaped_user->{username} = $tweet->{retweeted_status}{user}{screen_name};
        } else {
            $shaped_user->{id} = $tweet->{user}{id_str};
            $shaped_user->{username} = $tweet->{user}{screen_name};
        }
        push(@{ $ret->{includes}{users} }, $shaped_user);

        # v2 media
        my $shaped_media = {};
        if ($tweet->{extended_entities}{media}) {
            for my $media (@{ $tweet->{extended_entities}{media} }) {
                $shaped_media->{media_key} = $media->{id_str};
                $shaped_media->{type} = $media->{type};
                if ($media->{type} eq 'photo') {
                    $shaped_media->{url} = $media->{media_url};
                } elsif ($media->{type} eq 'video') {
                    $shaped_media->{variants} = $media->{video_info}{variants};
                }
                push(@{ $ret->{includes}{media} }, $shaped_media);
            }
        }
    }

    # v2 pagination_token and oldest_id
    if (scalar(@$tweets) <= 2) {
        $ret->{meta}{next_token} = undef;
        $ret->{meta}{oldest_id} = undef
    } else {
        $ret->{meta}{next_token} = $tweets->[-1]{id_str};
        $ret->{meta}{oldest_id} = $tweets->[-1]{id_str};
    }

    return $ret;
}

sub _get_user_favorites {
    my ($self, $user_id, $pagination_token) = @_;

    if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
        my $pagination_param = defined($pagination_token) ? "&pagination_token=$pagination_token" : "";
        my $ret = $self->twitter_primary->get("users/$user_id/liked_tweets?expansions=author_id,referenced_tweets.id,attachments.media_keys,referenced_tweets.id.author_id&media.fields=url,variants&max_results=100$pagination_param");
        return $ret;
    } else {
        my $pagination_param = defined($pagination_token) ? { max_id => $pagination_token } : {};
        my $tweets = $self->twitter_primary->favorites({ user_id => $user_id, count => 200, %$pagination_param });
        return $self->_v2_shaping($tweets);
    }
}

sub _get_users_favorites {
    my ($self, $users_id) = @_;

    my $pm = Parallel::ForkManager->new($self->nproc);
    my $users_favorites = {};
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_objects = $_[5];
        push(@{ $users_favorites->{referenced_tweets} }, @{ $all_objects->{referenced_tweets} }) if $all_objects->{referenced_tweets};
        push(@{ $users_favorites->{tweets} }, @{ $all_objects->{tweets} }) if $all_objects->{tweets};
        push(@{ $users_favorites->{users}  }, @{ $all_objects->{users} })  if $all_objects->{users};
        push(@{ $users_favorites->{media}  }, @{ $all_objects->{media} })  if $all_objects->{media};
    });
    for my $user_id (@$users_id) {
        $pm->start($user_id) and next;
        my $all_objects = {};
        my $pagination_token;
        my $user_name = $self->_get_user_screen_name($user_id);
        last unless $user_name;
        while (1) {
            my $res = eval { $self->_get_user_favorites($user_id, $pagination_token) };
            last if $@;
            last unless $res->{data};
            push(@{ $all_objects->{tweets} }, @{ $res->{data} });
            push(@{ $all_objects->{referenced_tweets} }, @{ $res->{includes}{tweets} }) if $res->{includes}{tweets};
            push(@{ $all_objects->{users}  }, @{ $res->{includes}{users} })  if $res->{includes}{users};
            push(@{ $all_objects->{media}  }, @{ $res->{includes}{media} })  if $res->{includes}{media};
            last unless $res->{meta}{next_token};
            $pagination_token = $res->{meta}{next_token};
            $self->logger->info('Got '. $user_name. '\'s favorites. Continuing...');
        }
        $pm->finish(0, $all_objects);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$users_id). ' users '. scalar(@$users_favorites). ' favorites.');

    return $users_favorites;
}

sub _get_user_screen_name {
    my ($self, $user_id) = @_;

    if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
        return $self->twitter_primary->get("users/$user_id")->{data}{username};
    } else {
        return $self->twitter_primary->show_user({ user_id => $user_id })->{screen_name};
    }
}

sub _get_user_timeline {
    my ($self, $user_id, $pagination_token) = @_;

    if ($self->settings->{twitter}{secondary_credentials}{use_v2_api}) {
        my $pagination_param = defined($pagination_token) ? "&pagination_token=$pagination_token" : "";
        my $ret = $self->twitter_secondary->get("users/$user_id/tweets?expansions=author_id,referenced_tweets.id,attachments.media_keys,referenced_tweets.id.author_id&media.fields=url,variants&max_results=100$pagination_param");
        return $ret;
    } else {
        my $pagination_param = defined($pagination_token) ? { max_id => $pagination_token } : {};
        my $tweets = $self->twitter_secondary->user_timeline({ user_id => $user_id, count => 200, %$pagination_param });
        return $self->_v2_shaping($tweets);
    }
}

sub _get_user_timelines {
    my ($self, $user_ids) = @_;

    my $pm = Parallel::ForkManager->new($self->nproc);
    my $users_timeline = {};
    $pm->run_on_finish(sub {
        my $code = $_[1];
        my $all_objects = $_[5];
        push(@{ $users_timeline->{referenced_tweets} }, @{ $all_objects->{referenced_tweets} }) if $all_objects->{referenced_tweets};
        push(@{ $users_timeline->{tweets} }, @{ $all_objects->{tweets} }) if $all_objects->{tweets};
        push(@{ $users_timeline->{users}  }, @{ $all_objects->{users} })  if $all_objects->{users};
        push(@{ $users_timeline->{media}  }, @{ $all_objects->{media} })  if $all_objects->{media};
    });
    for my $user_id (@$user_ids) {
        $pm->start($user_id) and next;
        my $all_objects = {};
        my $pagination_token;
        my $user_name = $self->_get_user_screen_name($user_id);
        last unless $user_name;
        my $is_stored_member = $self->stored_list_members->get($user_id) ? 1 : undef;
        my $tweets_count = 0;
        while (1) {
            my $res = eval { $self->_get_user_timeline($user_id, $pagination_token) };
            last if $@;
            last unless $res->{data};
            $tweets_count += scalar(@{ $res->{data} });
            push(@{ $all_objects->{tweets} }, @{ $res->{data} });
            push(@{ $all_objects->{referenced_tweets} }, @{ $res->{includes}{tweets} }) if $res->{includes}{tweets};
            push(@{ $all_objects->{users}  }, @{ $res->{includes}{users} })  if $res->{includes}{users};
            push(@{ $all_objects->{media}  }, @{ $res->{includes}{media} })  if $res->{includes}{media};
            last unless $res->{meta}{next_token};
            $pagination_token = $res->{meta}{next_token};
            my $oldest_id = $res->{meta}{oldest_id};
            if ($is_stored_member) {
                last if $tweets_count >= 200;
                $self->logger->info("Got $user_name ($user_id)'s tweets. Next start with oldest_id=$oldest_id");
            } else {
                last if $tweets_count >= 3200;
                $self->logger->info("Got $user_name ($user_id)'s tweets. Next start with oldest_id=$oldest_id");
            }
        }
        $pm->finish(0, $all_objects);
    }
    $pm->wait_all_children;

    $self->logger->info('Got all '. scalar(@$user_ids). ' users, '. scalar(@{ $users_timeline->{tweets} }). ' tweets.');

    return $users_timeline;
}

sub _get_list_name {
    my ($self, $list_id) = @_;

    if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
        return $self->twitter_primary->get("lists/$list_id")->{data}{name};
    } else {
        return $self->twitter_primary->show_list({ list_id => $list_id })->{name};
    }
}

sub _get_list_members_id {
    my ($self, $list_id, $pagination_token) = @_;

    if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
        my $pagination_param = defined($pagination_token) ? "&pagination_token=$pagination_token" : "";
        my $list_members = $self->twitter_primary->get("lists/$list_id/members?max_results=100$pagination_param");
        my $members_id = [map { $_->{id} } @{ $list_members->{data} }];
        $pagination_token = $list_members->{meta}{next_token};
        return ($members_id, $pagination_token);
    } else {
        my $list_members = $self->twitter_primary->list_members({list_id => $list_id, count => 5000})->{users};
        my $members_id = [map { $_->{id_str} } @$list_members];
        $pagination_token = undef;
        return ($members_id, $pagination_token);
    }
}

sub _extract_file_name_and_url {
    my ($self, $all_objects) = @_;
    my $media_info = {};
    for my $media (@{ $all_objects->{media} }) {
        my $author_id;
        my $tweet_id;

        for my $referenced_tweet (@{ $all_objects->{referenced_tweets} }) {
            if (grep { $_ eq $media->{media_key} } @{ $referenced_tweet->{attachments}{media_keys} }) {
                $author_id = $referenced_tweet->{author_id};
                $tweet_id  = $referenced_tweet->{id};
                last;
            }
        }
        if (!defined($author_id) and !defined($tweet_id)) {
            for my $tweet (@{ $all_objects->{tweets} }) {
                if (grep { $_ eq $media->{media_key} } @{ $tweet->{attachments}{media_keys} }) {
                    $author_id = $tweet->{author_id};
                    $tweet_id  = $tweet->{id};
                    last;
                }
            }
        }

        if ($media->{type} eq 'photo') {
            my $url = $media->{url};
            my $filename = $author_id."-".$tweet_id."-".basename($url);
            next if $self->stored_media_files->get($filename);
            $media_info->{$filename} = $url. '?name=orig';
        } elsif ($media->{type} eq 'video') {
            my $video_variants = $media->{variants};
            for my $video_variant (@$video_variants) { $video_variant->{bitrate} = 0 unless $video_variant->{bitrate} }
            my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video_variants)[0]{url};
            $url =~ s/\?.+//;
            my $filename = $author_id."-".$tweet_id."-".basename($url);
            next if $self->stored_media_files->get($filename);
            $media_info->{$filename} = $url;
        }
    }

    $self->logger->info('Extracted '. scalar(%$media_info). ' media files.');
    if ($self->redownload_list->dbsize > 0) {
        $media_info->{$_} = $self->redownload_list->get($_) for $self->redownload_list->keys('*');
    }
    return $media_info;
}

sub _notify_to_slack_if_not_read_yet {
    my ($self, $status) = @_;
    my $orig_status = $status->{retweeted_status} ? $status->{retweeted_status} : $status;
    my $user_id = $orig_status->{user}{id_str};
    my $user_screen_name = $orig_status->{user}{screen_name};
    my $status_id = $orig_status->{id_str};

    return if grep {$user_id eq $_} @{ $self->current_list_members };
    return if $self->stored_list_members->get($user_id);
    return if $self->read_members->get($user_id);

    if ($self->settings->{discord_webhook_url}) {
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
    }

    if ($self->settings->{slack_webhook_url}) {
        my $payload = encode_json({
            text => "https://twitter.com/$user_screen_name/status/$status_id"
        });

        my $res = $self->http->post(
            $self->settings->{slack_webhook_url},
            [],
            [ payload => $payload ]
        );

        print("Slack notified: return code ". $res->code. "\n");
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
            my $res = $self->http->get($media_urls->{$filename});
            if ($res->code != 200 or $res->content =~ /timeout/) {
                $self->logger->warn("Cannot download this media file $filename ($media_urls->{$filename}) with HTTP Status Code ". $res->code);
                $self->redownload_list->set($filename, $media_urls->{$filename}) if ($res->code =~ /^5/ or $res->code == 429);
                $pm->finish(-1, [$filename, undef]);
            }
            $self->redownload_list->del($filename) if $self->redownload_list->get($filename);
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
