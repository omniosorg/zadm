package Zadm::Zone::Emu;
use Mojo::Base 'Zadm::Zone::KVM', -signatures;

use Mojo::File;
use Mojo::URL;

has ibrand   => sub($self) { $self->brand };
has template => sub($self) {
    my $template = $self->SUPER::template;

    return {
        %{$self->SUPER::template},
        $self->hasimg ? %{$self->image->metadata->{attr} || {}} : (),
    }
};

# public methods
sub install($self, @args) {
    $self->SUPER::install(@args);

    return 1 if $ENV{__ZADM_ALTROOT} || !$self->hasimg
        || !$self->utils->isArrRef($self->image->metadata->{res});

    # TODO: we could parallelise this; however, we just have one resource so far at maximum
    # the advantage of doing it sequentially is that we can print progress
    for my $res (@{$self->image->metadata->{res}}) {
        my $file = Mojo::File->new($self->config->{zonepath}, 'root', Mojo::File->new($res)->basename);
        my $url = Mojo::URL->new("/media/$res")->base($self->image->provider->baseurl)->to_abs;

        $self->zones->images->curl([{ path => $file, url => $url }]);
    }
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid|image_path_or_uri>] [-t <template_path>] <zone_name>
    delete [-f] <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-i <image_uuid|image_path_or_uri>] [-f] <zone_name>
    uninstall [-f] <zone_name>
    show [zone_name [property[,property]...]]
    list [-H] [-F <format>] [-b <brand>] [-s <state>] [zone_name]
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    pull <image_uuid>
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop [-c [extra_args]] <zone_name>
    restart [-c [extra_args]] <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    console [extra_args] <zone_name>
    monitor <zone_name>
    vnc [-w] [<[bind_addr:]port>] <zone_name>
    webvnc [<[bind_addr:]port>] <zone_name>
    log <zone_name>
    snapshot [-d] <zone_name> [<snapname>]
    rollback [-r] <zone_name> <snapname>
    help [-b <brand>]
    doc [-b <brand>] [-a <attribute>]
    man
    version

=head1 COPYRIGHT

Copyright 2023 OmniOS Community Edition (OmniOSce) Association.

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
