package Devourer::MetaFetcher::Services::Twitter;

use Mojo::Base -base, -signatures, -async_await;
use Twitter::API;
use Devourer::Container qw/con/;

has twitter_config => sub ($self) { con('config')->{services}{twitter} };
has twitter_client => sub ($self) {
    Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        consumer_key        => $self->twitter_config->{credentials}{consumer_key},
        consumer_secret     => $self->twitter_config->{credentials}{consumer_secret},
        access_token        => $self->twitter_config->{credentials}{access_token},
        access_token_secret => $self->twitter_config->{credentials}{access_token_secret},
    );
};
has current_list_members => sub ($self) {
    my $arr = [];
    push(@$arr, @{ $self->_get_list_members($_) }) for @{ $self->twitter_config->{components}{lists} };
    return $arr;
};
has already_read_list_members => sub {
    Devourer::Models::Twitter::AlreadyReadListMembers->new;
};
has already_read_users => sub {
    Devourer::Models::Twitter::AlreadyReadUsers->new;
};

sub _get_list_members ($self, $list_id) {
    my $list_members = $self->twitter_client->list_members({list_id => $list_id, count => 5000})->{users};
    my $list_member_ids = [map { $_->{id_str} } @$list_members];

    con('logger')->info('Got '. scalar(@$list_member_ids). ' members screen name.');

    return $list_member_ids;
}

sub _get_user_timeline ($self, $user_id) {
    my $all_statuses;
    my $max_id;
    my $is_already_read_list_member = $self->already_read_list_members->get($user_id) ? 1 : undef;
    for my $iter (1..16) {
        my $statuses = eval { $self->twitter_client->user_timeline({user_id => $user_id, count => 200, defined($max_id) ? (max_id => $max_id) : ()}) };
        last unless defined($statuses);
        my $screen_name = $statuses->[0]{user}{screen_name};
        push(@$all_statuses, @$statuses);
        $max_id = $statuses->[-1]{id_str};
        if ($is_already_read_list_member) {
            con('logger')->info("Got $screen_name ($user_id)'s statuses");
            last;
        } else {
            con('logger')->info("Got $screen_name ($user_id)'s statuses. Next start with max_id=$max_id");
        }
        last if scalar(@$statuses) <= 1;
    }

    return $all_statuses;
}

sub _extract_filename_and_url ($self, $statuses) {
    my $component = (caller)[0];
    my $media_info = {};
    for my $status (@$statuses) {
        my $media_array = $status->{extended_entities}{media};
        next unless $media_array;
        $self->notify($status) if grep {$component eq $_} @{ $self->twitter_config->{notify}{allow_components} };;
        my $status_id = $media_array->[0]{source_status_id_str} ? $media_array->[0]{source_status_id_str} : $status->{id_str};
        my $user_id = $status->{retweeted_status} ? $status->{retweeted_status}{user}{id_str} : $status->{user}{id_str};
        if ($media_array->[0]{video_info}) {
            my $video = $media_array->[0]{video_info}{variants};
            for (@$video) { $_->{bitrate} = 0 unless $_->{bitrate} }
            my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video)[0]{url};
            $url =~ s/\?.+//;
            my $filename = $user_id."-".$status_id."-".basename($url);
            $media_info->{$filename} = $url;
        } else {
            for my $media (@$media_array) {
                my $url = $media->{media_url};
                my $filename = $user_id."-".$status_id."-".basename($url);
                $media_info->{$filename} = $url. '?name=orig';
            }
        }
    }

    con('logger')->info('Extracted '. scalar(%$media_info). ' media files.');

    return $media_info;
}

sub _notify ($self, $status) {
    my $orig_status = $status->{retweeted_status} ? $status->{retweeted_status} : $status;
    my $user_id = $orig_status->{user}{id_str};
    my $user_screen_name = $orig_status->{user}{screen_name};
    my $status_id = $orig_status->{id_str};

    return if grep {$user_id eq $_} @{ $self->current_list_members };
    return if $self->already_read_list_members->get($user_id);
    return if $self->already_read_users->get($user_id);

    con('minion')->enqueue(notify => "https://twitter.com/${user_screen_name}/status/${status_id}");
}

1;
