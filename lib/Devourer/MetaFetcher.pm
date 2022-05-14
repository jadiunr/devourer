package Devourer::MetaFetcher;
use Mojo::Base -base, -signatures;
use String::CamelCase qw/camelize/;
use Module::Load;
use Devourer::Container qw/con/;

sub run ($self, $service, $component) {
    my $class = "Devourer::MetaFetcher::Services::@{[ camelize($service) ]}::@{[ camelize($component) ]}";
    load $class;

    $class->new->run;
}

1;
