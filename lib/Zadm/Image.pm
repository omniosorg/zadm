package Zadm::Image;
use Mojo::Base -base;

use Mojo::Home;
use Mojo::Exception;
use Mojo::File;
use File::Spec;
use File::Temp;
use Time::Piece;
use Time::Seconds qw(ONE_DAY);

my $MODPREFIX = __PACKAGE__;

# private methods
my $getImgProv = sub {
    my $self  = shift;
    my $uuid  = shift;
    my $brand = shift;

    my @imgs;
    my $provider;
    for my $prov (keys %{$self->images}) {
        if (my @provimgs = grep { $_->{brand} eq $brand && $_->{uuid} =~ /$uuid/ } @{$self->images->{$prov}}) {
            push @imgs, @provimgs;
            $provider = $prov;
        }
    }

    @imgs < 1 and Mojo::Exception->throw("ERROR: $brand image UUID containing '$uuid' not found.\n");
    @imgs > 1 and Mojo::Exception->throw("ERROR: more than one $brand image uuid contains '$uuid'.\n");

    # TODO: adding provider for now for postInstall. we should not expose the provider but
    # rework the interface so Zadm::Image can take care of postInstall
    return { %{$imgs[0]}, _provider => $self->provider->{$provider} };
};

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub { Zadm::Utils->new(log => shift->log) };
has datadir  => sub { Mojo::Home->new->detect(__PACKAGE__)->rel_file('var')->to_string };
has cache    => sub { shift->datadir . '/cache' };
has images   => sub { {} };

has provider => sub {
    my $self = shift;

    my %provider;
    for my $path (@INC) {
        my @mDirs = split /::/, $MODPREFIX;
        my $fPath = File::Spec->catdir($path, @mDirs, '*.pm');
        for my $file (sort glob $fPath) {
            my ($volume, $modulePath, $modName) = File::Spec->splitpath($file);
            $modName =~ s/\.pm$//;
            next if $modName eq 'base';

            my $module = $MODPREFIX . '::' . $modName;
            my $mod = do {
                eval "require $module";
                $module->new(log => $self->log, utils => $self->utils, datadir => $self->datadir);
            } or next;
            $provider{$mod->provider} = $mod;
        }
    }

    return \%provider;
};

sub getImage {
    my $self  = shift;
    my $uuid  = shift;
    my $brand = shift;

    $self->fetchImages;

    # check if uuid points to a local image
    my $abspath = Mojo::File->new($uuid)->to_abs;
    return { _file => $abspath } if -r $abspath;

    if ($uuid =~ /^http/) {
        $self->log->debug("downloading $uuid...");

        my $tmpimgdir = File::Temp->newdir(DIR => $self->cache);
        my $fileName  = Mojo::File->new($uuid)->basename;

        $self->utils->curl("$tmpimgdir/$fileName", $uuid);
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

sub fetchImages {
    my $self  = shift;
    my $force = shift;

    do {
        $self->provider->{$_}->fetchImages($force);
        $self->images->{$_} = $self->provider->{$_}->images;
    } for keys %{$self->provider};
}

sub dump {
    my $self = shift;
    my $opts = shift // {};

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

sub vacuum {
    my $self = shift;
    my $opts = shift // {};

    my $ts = localtime->epoch - ($opts->{days} // 30) * ONE_DAY;

    $self->provider->{$_}->vacuum($ts) for keys %{$self->provider};
}

1;

__END__

=head1 COPYRIGHT

Copyright 2020 OmniOS Community Edition (OmniOSce) Association.

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
