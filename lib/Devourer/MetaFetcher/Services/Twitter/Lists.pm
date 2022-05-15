package Devourer::MetaFetcher::Services::Twitter::Lists;
use Mojo::Base 'Devourer::MetaFetcher::Services::Twitter', -signatures, -async_await;
use Devourer::Container qw/con/;

sub run ($self) {
    $self->already_read_users->bulk_update($self->current_list_members);

    for my $list_member_id (@{ $self->current_list_members }) {
        my $statuses = $self->_get_user_timeline($list_member_id);
        my $media_info = $self->_extract_filename_and_url($statuses);

        while (my ($filename, $url) = each(%$media_info)) {
            con('minion')->enqueue('download', ['twitter', $filename, $url]);
        }
    }
}

1;
