package Devourer::MetaFetcher::Services::Twitter::Components::Users;
use Mojo::Base 'Devourer::MetaFetcher::Services::Twitter', -signatures, -async_await;
use Devourer::Container qw/con/;

sub run ($self) {
    for my $user_id (@{ $self->twitter_config->{components}{users} }) {
        my $favs = $self->_get_user_favorites($user_id);
        my $statuses = $self->_get_user_timeline($user_id);
        push(@$statuses, @$favs);
        my $media_info = $self->_extract_filename_and_url($statuses);
        
        while (my ($filename, $url) = each(%$media_info)) {
            con('minion')->enqueue('download', 'twitter', $filename, $url);
        }
    }
}

1;
