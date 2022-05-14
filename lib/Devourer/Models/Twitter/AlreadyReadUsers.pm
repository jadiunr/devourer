package Devourer::Models::Twitter::AlreadyReadUsers;
use Mojo::Base -base, -signatures;

sub get ($self, $user_id) {
    return con('pg')->db->select('twitter_already_read_users', ['id'], {twitter_user_id => $user_id})->hash->{id};
};

sub set ($self, $user_id) {
    return con('pg')->db->insert('twitter_already_read_users', {twitter_user_id => $user_id});
};
