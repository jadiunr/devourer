package Devourer::Notifier::Discord;
use Mojo::Base -base, -signatures;

has http => sub {
    Mojo::UserAgent->new;
};

sub run ($self, $url) {
    my $res = $self->http->post(con('config')->{notify}{webhook_endpoint_url} => json => {content => $url});
    if (!$res->is_success) {
        my $msg = "Notification job failed: ${url}";
        con('logger')->warn($msg);
        die $msg;
    }
}
