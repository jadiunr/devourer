package Devourer::Container;
use Mojo::Base -strict, -signatures;
use Object::Container -base;
use YAML::Tiny;
use Minion;
use Mojo::Pg;

register config => sub {
    YAML::Tiny->read('config.yml')->[0];
};

register minion => sub ($self) {
    Minion->new(Pg => $self->get('config')->{db}{minion});
};

register pg => sub ($self) {
    Mojo::Pg->new($self->get('config')->{db}{devourer});
};

register logger => sub ($self) {
    Mojo::Log->new(
        path => $self->get('config')->{logger}{path},
        level => $self->get('config')->{logger}{level},
    );
};

1;
