package Devourer::Models::Twitter::AlreadyReadUsers;
use Mojo::Base -base, -signatures;
use Devourer::Container qw/con/;

sub get ($self, $user_id) {
    return con('pg')->db->select('twitter_already_read_users', ['id'], {twitter_user_id => $user_id});
};

sub set ($self, $user_id) {
    return con('pg')->db->insert('twitter_already_read_users', {twitter_user_id => $user_id});
};

sub bulk_update ($self, $user_ids) {
    for my $user_id (@$user_ids) {
        my $id = con('pg')->db->select('twitter_already_read_users', ['id'], {twitter_user_id => $user_id});
        if (!$id) {
            con('pg')->db->insert('twitter_already_read_users', {twitter_user_id => $user_id});
        }
    }
};

1;
