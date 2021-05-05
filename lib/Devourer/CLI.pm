package Devourer::CLI;

sub run {
    my @args = @_;

    my $module = join '::', (grep {$_ !~ /^-/} @args);
    my $options = [grep {$_ =~ /^-/} @args];

    eval "require $module";
    die $@ if $@;

    my $command = $module->new;
    return $command->run($options);
}

1;
