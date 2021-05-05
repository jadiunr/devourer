package Devourer::CLI::fetch::twuser_all;
use Moo;
use utf8;
use feature 'say';
use Time::Piece;
use File::Basename 'basename';
use File::Path 'mkpath';
use Twitter::API;
use YAML::Tiny;
use Furl;
use Data::Dumper;

has settings => (is => 'ro', default => sub { YAML::Tiny->read('./settings.yml')->[0]; });
has http => (is => 'ro', default => sub { Furl->new(); });
has twitter => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    Twitter::API->new_with_traits(
        traits              => ['Enchilada', 'RateLimiting'],
        consumer_key        => $self->settings->{twitter}{consumer_key},
        consumer_secret     => $self->settings->{twitter}{consumer_secret},
        access_token        => $self->settings->{twitter}{access_token},
        access_token_secret => $self->settings->{twitter}{access_token_secret}
    );
});
has saved_files => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    [map {basename($_)} (split /\n/, `find @{[$self->settings->{outdir}]} -type f`)];
});
has saved_statuses => (is => 'ro', lazy => 1, default => sub {
    my $self = shift;
    my $statuses = [map {(split '-', basename($_))[0]} (split /\n/, `find @{[$self->settings->{outdir}]} -type d -name all -prune -o -type f -a -mtime -30 -print`)];
    $statuses = [grep {$_ =~ /^\d+$/} @$statuses];
    return [sort {$b <=> $a} @$statuses];
});

sub run {
    my $self = shift;

    for my $status (@{$self->saved_statuses}) {
        my $user_id = eval { $self->twitter->show_status($status)->{user}{id} };
        warn "$@: $status" and next if $@;
        
        my $max_id;
        for my $iter (1..16) {
            my $user_statuses;
            $user_statuses = $self->twitter->user_timeline({user_id => $user_id, count => 200}) if !defined($max_id);
            $user_statuses = $self->twitter->user_timeline({user_id => $user_id, count => 200, max_id => $max_id}) if defined($max_id);
            
            for my $user_status (@$user_statuses) {
                my $media_array = $user_status->{extended_entities}{media};
                $self->download($media_array, $user_status->{id}) if $media_array;
            }

            my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
            my $user_timeline_limit = $rate_limit_status->{statuses}{'/statuses/user_timeline'};
            my $show_statuses_limit = $rate_limit_status->{statuses}{'/statuses/show/:id'};

            say "user_timeline limit: ". $user_timeline_limit->{remaining}. "/". $user_timeline_limit->{limit};
            say "show_statuses_limit: ". $show_statuses_limit->{remaining}. "/". $show_statuses_limit->{limit};

            last if scalar(@$user_statuses) < 200;
        }
    }
}

sub download {
    my $self = shift;
    my $media_array = shift;
    my $status_id = $media_array->[0]{source_status_id} ? $media_array->[0]{source_status_id} : shift;
    my $binary;

    if($media_array->[0]{video_info}) {
        my $video = $media_array->[0]{video_info}{variants};
        for (@$video) { $_->{bitrate} = 0 unless $_->{bitrate} }
        my $url = (sort { $b->{bitrate} <=> $a->{bitrate} } @$video)[0]{url};
        $url =~ s/\?.+//;

        my $filename = $status_id."-".basename($url);

        if (grep {$filename eq $_} @{$self->saved_files} or -f "@{[$self->settings->{outdir}]}/$filename") {
            say "[@{[ localtime->datetime ]}]Already saved     : $filename";
            return;
        }

        $binary = $self->http->get($url);
        warn "[@{[ localtime->datetime ]}]Cannot fetch video: returned " . $binary->code . ", url: $url" and return
            if grep {$_ eq $binary->code} (404, 500);
        $self->save($filename, $binary);
    } else {
        for my $image (@$media_array) {
            my $url = $image->{media_url};

            my $filename = $status_id."-".basename($url);
            if (grep {$filename eq $_} @{$self->saved_files} or -f "@{[$self->settings->{outdir}]}/$filename") {
                say "[@{[ localtime->datetime ]}]Already saved     : $filename";
                return;
            }

            $binary = $self->http->get($url.'?name=orig');
            warn "[@{[ localtime->datetime ]}]Cannot fetch image: returned " . $binary->code . ", url: $url" and next
                if grep {$_ eq $binary->code} (404, 500);
            $self->save($filename, $binary);
        }
    }
}

sub save {
  my ($self, $filename, $binary) = @_;

  open my $fh, ">", "./@{[$self->settings->{outdir}]}/$filename"
    or die "[@{[ localtime->datetime ]}]Cannot create file: $!, filename: ".$filename;
  say $fh $binary->content;
  close $fh;
  say "[@{[ localtime->datetime ]}]Image saved       : $filename";
}

1;
