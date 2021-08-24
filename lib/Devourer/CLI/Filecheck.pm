package Devourer::CLI::Filecheck;
use Moo;
use utf8;
use YAML::Tiny;
use Log::Dispatch;
use Parallel::ForkManager;
use Redis;

has nproc => (is => 'ro', default => sub { chomp(my $nproc = `nproc --all`); $nproc });
has logger => (is => 'ro', default => sub {
    Log::Dispatch->new(
        outputs => [['Screen', min_level => 'info', newline => 1]]
    );
});
has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0] });
has stored_media_files => (is => 'ro', default => sub { Redis->new(server => 'redis:6379'); });

sub run {
    my $self = shift;
    my $count = 0;
    my $pm = Parallel::ForkManager->new($self->nproc);

    while(my $files = $self->stored_media_files->scan($count, 'count', $self->nproc * 64)) {
        while(my $files_slice = [splice @{ $files->[1] }, 0, 64]) {
            $pm->start and last unless @$files_slice;
            $pm->start and next if @$files_slice;
            for my $file (@$files_slice) {
                my $path = $self->stored_media_files->get($file);
                if (-T $path) {
                    unlink $path;
                    $self->stored_media_files->del($file);
                    $self->logger->info("CORRUPTED FILE DELETED! : $path");
                } else {
                    $self->logger->info("OK : $path");
                }
            }
            $pm->finish;
        }
        $pm->wait_all_children;
        last if $files->[0] eq '0';
        $count = $files->[0];
    }
}

1;
