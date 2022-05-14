package Devourer::Models::Twitter::SavedMediaFiles;
use Mojo::Base -base, -signatures;

sub get ($self, $filename) {
    return con('pg')->db->select('twitter_saved_media_files', ['id'], {filename => $filename})->hash->{id};
};

sub set ($self, $service, $filename, $filepath) {
    return con('pg')->db->insert('twitter_saved_media_files', {
        service_name => $service,
        filename => $filename,
        filepath => $filepath,
    });
};
