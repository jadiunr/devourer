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
        consumer_key        => $self->settings->{twitter}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{consumer_secret},
        access_token        => $self->settings->{twitter}{access_token},
        access_token_secret => $self->settings->{twitter}{access_token_secret}
    );
});

sub run {
    my $self = shift;
    my $list_members = [];
    push(@$list_members, @{ $self->_get_list_members($_) }) for @{ $self->settings->{lists} };
    my $muted_users = [];
    my $next_cursor = 0;
    do {
        my $mutes = $self->twitter->mutes({stringify_ids => '1', cursor => $next_cursor});
        push(@$muted_users, @{ $mutes->{ids} });
        $next_cursor = $mutes->{next_cursor_str};
    } while ($next_cursor);

    for my $muted_user (@$muted_users) {
        my ($index) = grep { $muted_user eq $list_members->[$_] } 0..scalar(@$list_members)-1;
        splice(@$list_members, $index, 1) if defined($index);
    }
    for (@$list_members) {
        $self->twitter->create_mute({user_id => $_});
        $self->logger->info("Muted: $_");
        sleep 1;
    }
}

sub _get_list_members {
    my ($self, $list_id) = @_;

    my $members = $self->twitter->list_members({list_id => $list_id, count => 5000})->{users};
    my $member_ids = [map { $_->{id_str} } @$members];

    $self->logger->info('Got '. scalar(@$member_ids). ' members screen name.');

    return $member_ids;
}

1;
