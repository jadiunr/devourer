package Devourer::Models::Twitter::AlreadyReadListMembers;
use Mojo::Base -base, -signatures;
use Devourer::Container qw/con/;

sub get ($self, $user_id) {
    return con('pg')->db->select('twitter_already_read_list_members', ['id'], {twitter_user_id => $user_id});
};

sub set ($self, $user_id) {
    return con('pg')->db->insert('twitter_already_read_list_members', {twitter_user_id => $user_id});
};

1;
