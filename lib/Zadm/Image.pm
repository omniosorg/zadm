package Zadm::Image;
use Mojo::Base -base, -signatures;

use Mojo::Exception;
use Mojo::File;
use Mojo::Log;
use Mojo::Promise;
use Zadm::Image::base;
use Zadm::Images;

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has images   => sub($self) { Zadm::Zones->new(log => $self->log) };
has brand    => sub { Mojo::Exception->throw("ERROR: brand must be specified on instantiation.\n") };
has uuid     => sub { Mojo::Exception->throw("ERROR: uuid must be specified on instantiation.\n") };
# creating an instance of the base class as a stub.
# so the zone classes can safely call 'preSetConfig' and 'postInstall'
# when the image is not from a provider but from a local file or direct http download
has provider => sub { Zadm::Image::base->new };
has metadata => sub($self) {
    my $brand = $self->brand;
    my $uuid  = $self->uuid;

    # check if uuid points to a local image
    my $abspath = Mojo::File->new($uuid)->to_abs;
    if (-r $abspath) {
        $self->image({ _file => $abspath });

        return {};
    }

    if ($uuid =~ /^http/) {
        $self->attr(image => sub {
            my $tmpimgdir = File::Temp->newdir(DIR => $self->images->cache);
            my $fileName  = Mojo::File->new($self->uuid)->basename;
            my $file      = Mojo::File->new($tmpimgdir, $fileName);

            $self->images->curl([{ path => $file, url => $self->uuid }]);
            # TODO: add a check whether we got a tarball or zfs stream
            # and not e.g. a html document

            # adding a reference to the tmpdir object. once it gets out of scope
            # i.e. after zone install the temporary directory will be removed
            return {
                __tmpdir__ => $tmpimgdir,
                _file      => $file,
            };
        });

        return {};
    }

    my @imgs;
    my $provider;
    for my $prov (keys %{$self->images->images}) {
        if (my @provimgs = grep { $_->{brand} =~ /^$brand$/ && $_->{uuid} =~ /$uuid/ } @{$self->images->images->{$prov}}) {
            push @imgs, @provimgs;
            $provider = $prov;
        }
    }

    @imgs < 1 and Mojo::Exception->throw("ERROR: image UUID containing '$uuid' not found.\n");
    @imgs > 1 and Mojo::Exception->throw("ERROR: more than one image UUID contains '$uuid'.\n");

    my $img = $imgs[0];
    $self->log->info("found $img->{brand} image '$img->{name}' from provider '$provider'");
    $self->provider($self->images->provider->{$provider});

    return $img;
};

has image    => sub($self) {
    my $img = $self->metadata;

    $img->{_file} = $self->provider->download($img->{uuid}
        . ($img->{ext} // '.tar.gz'), $img->{img}, chksum => $img->{chksum});
    # TODO: instopt needs rework; e.g. joyent lx images are "type" : "lx-dataset"
    # but tarballs (i.e. need -t for install). for now we don't set type for the Joyent provider
    $img->{_instopt} = ($img->{type} // '') =~ /-dataset$/ ? '-s' : '-t';

    # return the whole structure including all the metadata
    return $img;
};

# constructor
sub new($class, @args) {
    my $self = $class->SUPER::new(@args);

    # initialise metadata early to check whether we got a valid uuid/brand pair
    $self->metadata;

    return $self;
}

# public methods
sub image_p($self) {
    my $p = Mojo::Promise->new;

    local $@;
    {
        local $SIG{__DIE__};

        $self->image;
    }

    return $@ ? $p->reject($@) : $p->resolve(1);
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

S<Dominik Hassler E<lt>hadfl@omnios.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
