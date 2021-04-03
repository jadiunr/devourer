package Devourer::CLI::fetch::twitter;
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

sub run {
    my $self = shift;

    my $mediators = $self->settings->{mediators};
    my $all_statuses = [];

    {
        my $max_id;
        for my $iter (1..4) {
            my $timeline;
            $timeline = $self->twitter->home_timeline({count => 200}) if !defined($max_id);
            $timeline = $self->twitter->home_timeline({count => 200, max_id => $max_id}) if defined($max_id);
            push(@$all_statuses, @$timeline);
            $max_id = $timeline->[-1]{id};
        }
    }

    for my $mediator (@$mediators) {
        my $max_id;
        for my $iter (1..4) {
            my $favorites;
            $favorites = $self->twitter->favorites({screen_name => $mediator, count => 200}) if !defined($max_id);
            $favorites = $self->twitter->favorites({screen_name => $mediator, count => 200, max_id => $max_id}) if defined($max_id);
            push(@$all_statuses, @$favorites);
            $max_id = $favorites->[-1]{id};
        }
    }

    my %tmp;
    my $unique_statuses = [grep {!$tmp{$_->{id}}++} @$all_statuses];
    my $sorted_statuses = [sort {
        Time::Piece->strptime($a->{created_at}, '%a %b %d %T %z %Y')
        <=>
        Time::Piece->strptime($b->{created_at}, '%a %b %d %T %z %Y')
    } @$unique_statuses];

    for my $status (@$sorted_statuses) {
        my $media_array = $status->{extended_entities}{media};
        $self->download($media_array, $status->{id}) if $media_array;
    }

    my $rate_limit_status = $self->twitter->rate_limit_status()->{resources};
    say Dumper $rate_limit_status->{favorites};
    say Dumper $rate_limit_status->{statuses}{'/statuses/home_timeline'};
    say Dumper $rate_limit_status->{statuses}{'/statuses/user_timeline'};
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
