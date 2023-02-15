package Devourer::CLI::Twitter::Automute;
use Moo;
use utf8;
use Twitter::API;
use YAML::Tiny;
use Log::Dispatch;

has logger => (is => 'ro', default => sub {
    Log::Dispatch->new(
        outputs => [['Screen', min_level => 'info', newline => 1]]
    );
});
has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0] });
has twitter => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        ($self->settings->{twitter}{primary_credentials}{use_v2_api} ? (api_version => "2") : ()),
        ($self->settings->{twitter}{primary_credentials}{use_v2_api} ? (api_ext => "") : ()),
        consumer_key        => $self->settings->{twitter}{primary_credentials}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{primary_credentials}{consumer_secret},
        access_token        => $self->settings->{twitter}{primary_credentials}{access_token},
        access_token_secret => $self->settings->{twitter}{primary_credentials}{access_token_secret}
    );
});

sub run {
    my $self = shift;

    my $self_user_id = $self->settings->{twitter}{self_user_id};
    my $list_members = [];
    my $muted_users = [];

    # Fetch all list members
    my $count = 0;
    while (my $list_members_slice = $self->all_list_members->scan($count, 'count', 1000)) {
        push(@$list_members, @{ $list_members_slice->[1] });
        last if $list_members_slice->[0] eq "0";
        $count = $list_members_slice->[0];
    }

    # Fetch all muted users
    my $pagination_token;
    while (1) {
        if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
            my $pagination_param = defined($pagination_token) ? "&pagination_token=$pagination_token" : "";
            my $res = $self->twitter->get("users/$self_user_id/muting?max_results=1000$pagination_param");
            last unless $res->{data};
            push(@$muted_users, (map { $_->{id} } @{ $res->{data} }));
            last unless $res->{meta}{next_token};
            $pagination_token = $res->{meta}{next_token};
        } else {
            $pagination_token = 0 unless defined($pagination_token);
            my $res = $self->twitter->mutes({stringify_ids => '1', cursor => $next_cursor});
            last unless $res->{ids};
            push(@$muted_users, @{ $res->{ids} });
            last unless $res->{next_cursor_str}
            $pagination_token = $res->{next_cursor_str};
        }
    }

    # Extract unmuted users
    for my $muted_user (@$muted_users) {
        my ($index) = grep { $muted_user eq $list_members->[$_] } 0..scalar(@$list_members)-1;
        splice(@$list_members, $index, 1) if defined($index);
    }

    # Create muting
    for (@$list_members) {
        if ($self->settings->{twitter}{primary_credentials}{use_v2_api}) {
            my $res = $self->twitter->post("users/$self_user_id/muting?target_user_id=$_");
            $self->logger->info("Mute succeeded: $_") if $res->{data}{muting};
            $self->logger->warn("Mute failed: $_") unless $res->{data}{muting};
        } else {
            my $res = $self->twitter->create_mute({user_id => $_});
            $self->logger->info("Mute succeeded: $_") if $res->{muting};
            $self->logger->warn("Mute failed: $_") unless $res->{muting};
        }
    }
}

1;
