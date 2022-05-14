package Devourer::Notifier;
use Mojo::Base -base, -signatures;
use String::CamelCase qw/camelize/;
use Module::Load;
use Devourer::Container qw/con/;

sub run ($self, $url) {
    my $class = "Devourer::Notifier::@{[ camelize(con('config')->{notify}{service}) ]}";
    load $class;

    $class->new->run($url);
}

1;
