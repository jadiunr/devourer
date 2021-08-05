package Devourer::CLI;

sub run {
    my $class = shift;
    my $module = join '::', (map {ucfirst $_} (grep {$_ !~ /^-/} ($class, @ARGV)));

    eval "require $module";
    die $@ if $@;

    my $command = $module->new;
    return $command->run;
}

1;
