package Devourer::Models::SavedMediaFiles;
use Mojo::Base -base, -signatures;
use Devourer::Container qw/con/;

sub get ($self, $filename) {
    return con('pg')->db->select('saved_media_files', ['id'], {filename => $filename});
};

sub set ($self, $service, $filename, $filepath) {
    return con('pg')->db->insert('saved_media_files', {
        service_name => $service,
        filename => $filename,
        filepath => $filepath,
    });
};

1;
