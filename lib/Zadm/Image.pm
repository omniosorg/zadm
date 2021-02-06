package Zadm::Image;
use Mojo::Base -base, -signatures;

use Mojo::Home;
use Mojo::Exception;
use Mojo::File;
use Mojo::Loader qw(load_class);
use Mojo::Promise;
use Mojo::UserAgent;
use IO::Handle;
use IO::Uncompress::AnyUncompress qw($AnyUncompressError);
use File::Temp;
use Time::Piece;
use Time::Seconds qw(ONE_DAY);

# private methods
my $getImgProv = sub($self, $uuid, $brand) { # brand is potentially a regexp don't use it stringified
    my @imgs;
    my $provider;
    for my $prov (keys %{$self->images}) {
        if (my @provimgs = grep { $_->{brand} =~ /^(?:$brand)$/ && $_->{uuid} =~ /$uuid/ } @{$self->images->{$prov}}) {
            push @imgs, @provimgs;
            $provider = $prov;
        }
    }

    @imgs < 1 and Mojo::Exception->throw("ERROR: image UUID containing '$uuid' not found.\n");
    @imgs > 1 and Mojo::Exception->throw("ERROR: more than one image UUID contains '$uuid'.\n");

    # TODO: adding provider for now for postInstall. we should not expose the provider but
    # rework the interface so Zadm::Image can take care of postInstall
    return { %{$imgs[0]}, _provider => $self->provider->{$provider} };
};

my $progStr = sub($self, $bytes, $elapsed, $len = 0) {
    my $rate = $bytes / $elapsed;

    $len && return sprintf ('%s/%s %s [%s/s] [ETA: %-8s]',
        $self->utils->prettySize($bytes, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        $self->utils->prettySize($len, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        Time::Piece->new($elapsed)->hms,
        $self->utils->prettySize($rate, '%.1f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        ($rate ? Time::Piece->new(($len - $bytes) / $rate)->hms : '-'));

    return sprintf ('%s %s [%s/s]',
        $self->utils->prettySize($bytes, '%.0f%s', [ qw(b KiB MiB GiB TiB PiB) ]),
        Time::Piece->new($elapsed)->hms,
        $self->utils->prettySize($rate, '%.1f%s', [ qw(b KiB MiB GiB TiB PiB) ]));
};

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub($self) { Zadm::Utils->new(log => $self->log) };
has datadir  => sub { Mojo::Home->new->detect(__PACKAGE__)->rel_file('var')->to_string };
has cache    => sub($self) { $self->datadir . '/cache' };
has images   => sub { {} };
has ua       => sub { Mojo::UserAgent->new->max_redirects(8) };
has uaprog   => sub($self) {
    my $ua = $self->ua->new;

    $ua->on(start => sub($ua, $tx) {
        my $start = my $last = time;
        print 'Downloading ', $tx->req->url, "...\n";

        $tx->res->on(progress => sub($res) {
            my $now = time;
            if ($now > $last) {
                $last = $now;

                print "\r", $self->$progStr($res->content->progress,
                    $now - $start, $res->headers->content_length);
                STDOUT->flush;
            }
        });
        $tx->res->once(finish => sub($res) {
            print "\r", $self->$progStr($res->content->progress,
                time - $start, $res->headers->content_length), "\n";
            STDOUT->flush;
        });
    });

    return $ua;
};
has provider => sub($self) {
    my %provider;
    for my $module (@{$self->utils->getMods(__PACKAGE__)}) {
        next if load_class $module;

        my $mod = $module->new(log => $self->log, utils => $self->utils,
            datadir => $self->datadir, image => $self);

        $provider{$mod->provider} = $mod;
    }

    return \%provider;
};

# public methods
sub curl($self, $files, $opts = {}) {
    return if !@$files;
    $opts->{fatal} //= 1;

    $self->log->debug("downloading $_->{url}...") for @$files;
    Mojo::Promise->all(
        map { $opts->{silent} ? $self->ua->get_p($_->{url}) : $self->uaprog->get_p($_->{url}) } @$files
    )->then(sub(@tx) {
        for (my $i = 0; $i <= $#$files; $i++) {
            my $res = $tx[$i]->[0]->result;

            if (!$res->is_success) {
                my $err = "ERROR: Failed to download file from $files->[$i]->{url} - "
                    . $res->code . ' ' . $res->default_message . "\n";

                Mojo::Exception->throw($err) if $opts->{fatal};
                print STDERR $err;

                next;
            }

            local $@;
            eval {
                local $SIG{__DIE__};

                $res->save_to($files->[$i]->{path});
            };

            if ($@) {
                my $err = "ERROR: Failed to write file to $files->[$i]->{path}.\n";
                Mojo::Exception->throw($err) if $opts->{fatal};
                print STDERR $err;
            }
        }
    })->catch(sub($err) {
        Mojo::Exception->throw($err) if $opts->{fatal};
        print STDERR $err;
    })->wait;
}

sub zfsRecv($self, $file, $ds) {
    my @cmd = ($self->utils->getCmd('zfs'), qw(recv -Fv), $ds);

    $self->log->debug("@cmd");

    open my $zfs, '|-', @cmd or Mojo::Exception->throw("ERROR: receiving zfs stream: $!\n");
    my $decomp = IO::Uncompress::AnyUncompress->new($file->to_string)
        or Mojo::Exception->throw("ERROR: decompressing '$file' failed: $AnyUncompressError\n");

    my $bytes = 0;
    my $start = my $last = time;
    while (my $status = $decomp->read(my $buffer)) {
        Mojo::Exception->throw("ERROR: decompressing '$file' failed: $AnyUncompressError\n")
            if $status < 0;

        print $zfs $buffer;
        $bytes += $status;

        my $now = time;
        if ($now > $last) {
            $last = $now;

            print "\r", $self->$progStr($bytes, $now - $start);
            STDOUT->flush;
        }
    }
    print "\r", $self->$progStr($bytes, time - $start), "\n";
    STDOUT->flush;
}

sub fetchImages($self, $force = 0) {
    $self->curl(
        [
            map {{
                path => $self->provider->{$_}->idxpath,
                url  => $self->provider->{$_}->index
            }}
            grep { $force || $self->provider->{$_}->idxrefr }
            keys %{$self->provider}
        ],
        { silent => 1, fatal => 0 }
    );
    $self->images->{$_} = $self->provider->{$_}->images
        for keys %{$self->provider};
}

sub getImage($self, $uuid, $brand) { # brand is potentially a regexp don't use it stringified
    $self->fetchImages;

    # check if uuid points to a local image
    my $abspath = Mojo::File->new($uuid)->to_abs;
    return { _file => $abspath } if -r $abspath;

    if ($uuid =~ /^http/) {
        $self->log->debug("downloading $uuid...");

        my $tmpimgdir = File::Temp->newdir(DIR => $self->cache);
        my $fileName  = Mojo::File->new($uuid)->basename;

        $self->curl("$tmpimgdir/$fileName", $uuid);
        # TODO: add a check whether we got a tarball or zfs stream
        # and not e.g. a html document

        # adding a reference to the tmpdir object. once it gets out of scope
        # i.e. after zone install the temporary directory will be removed
        return {
            __tmpdir__ => $tmpimgdir,
            _file      => "$tmpimgdir/$fileName",
        };
    }

    my $img = $self->$getImgProv($uuid, $brand);
    $self->log->info("found $img->{brand} image '$img->{name}' from provider '"
        . $img->{_provider}->provider . "'");

    $img->{_file} = $img->{_provider}->download($img->{uuid}
        . ($img->{ext} // '.tar.gz'), $img->{img}, chksum => $img->{chksum});
    # TODO: instopt needs rework; e.g. joyent lx images are "type" : "lx-dataset"
    # but tarballs (i.e. need -t for install). for now we don't set type for the Joyent provider
    $img->{_instopt} = ($img->{type} // '') =~ /-dataset$/ ? '-s' : '-t';

    # return the whole structure including all the metadata
    return $img;
}

sub dump($self, $opts = {}) {
    $self->fetchImages($opts->{refresh});

    my @header = qw(UUID PROVIDER BRAND NAME VERSION);
    my $format = '%-10s%-10s%-8s%-36s%-16s';
    if ($opts->{verbose}) {
        push @header, 'DESCRIPTION';
        $format .= '%s';
    }
    $format .= "\n";

    # TODO: for now we assume that kvm images work under bhyve and vice versa
    my $brand = $opts->{brand} =~ /^(?:kvm|bhyve)$/ ? qr/kvm|bhyve/ : qr/$opts->{brand}/
        if $opts->{brand};

    printf $format, @header;
    for my $prov (grep { !$opts->{provider} || $_ eq $opts->{provider} } sort keys %{$self->images}) {
        printf $format, substr ($_->{uuid}, length ($_->{uuid}) - 8), $prov, $_->{brand}, $_->{name}, $_->{vers}, ($opts->{verbose} ? substr ($_->{desc}, 0, 40) : ()),
            for sort { $a->{brand} cmp $b->{brand} || $a->{name} cmp $b->{name} }
                grep { !$opts->{brand} || $_->{brand} =~ /^(?:$brand)$/ } @{$self->images->{$prov}};
    }
}

sub vacuum($self, $opts = {}) {
    my $ts = localtime->epoch - ($opts->{days} // 30) * ONE_DAY;

    $self->provider->{$_}->vacuum($ts) for keys %{$self->provider};
}

1;

__END__

=head1 COPYRIGHT

Copyright 2021 OmniOS Community Edition (OmniOSce) Association.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.
This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Dominik Hassler E<lt>hadfl@omniosce.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
