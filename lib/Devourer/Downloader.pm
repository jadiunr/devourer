package Devourer::Downloader;
use Mojo::Base -base, -signatures;
use Time::Piece;
use String::CamelCase qw/camelize/;
use File::Path 'mkpath';
use File::Basename qw/basename/;
use Devourer::Container qw/con/;

has saved_media_files => sub {
    Devourer::Models::SavedMediaFiles->new;
};

has http => sub {
    Mojo::UserAgent->new;
};

sub run ($self, $service, $filename, $url) {
    if ($self->saved_media_files->get($filename)) {
        con('logger')->debug("${filename} is already saved");
        return;
    }

    my $res = $self->http->get($url)->result;

    if (!$res->is_success or $res->headers->content_type !~ /^(image|video)/) {
        my $msg = "Cannot download this media file: ${filename} (${url}) with HTTP Status Code @{[ $res->code ]}";
        con('logger')->warn($msg);
        die $msg;
    }

    con('logger')->info("Media file downloaded: ${filename} (${url})");

    my $now = localtime;
    my ($year, $month, $day) = ($now->year, $now->strftime('%m'), $now->strftime('%d'));
    my $path = "@{[ con('config')->{outdir} ]}/@{[ camelize($service) ]}/${year}/${month}/${day}";

    mkpath $path and con('logger')->info("'${path}' directory is not exist, so a new one has been created") unless -d $path;

    open my $fh, ">", "${path}/${filename}" or die "Cannot create file: $!, filename: ${filename}";
    print $fh $res->body;
    close $fh;
    $self->saved_media_files->set($service, $filename, "${path}/${filename}");
    $self->logger->info("Media file stored in storage! filename: ${filename}");
}

1;
