package Zadm::Zone::Illumos;
use Mojo::Base 'Zadm::Zone::base';

has options => sub {
    my $self = shift;

    my $options = $self->SUPER::options;

    $options->{create}->{image} = {
        getopt => 'image|i=s',
        mand   => 1,
    };
    $options->{edit}->{image} = {
        getopt => 'image|i=s',
    };

    return $options;
};

sub install {
    my $self = shift;

    my $img = $self->zones->image->getImage($self->opts->{image}, $self->brand);

    $self->SUPER::install($img->{_instopt} // '-s', $img->{_file});
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> -i <image_uuid|image_path> [-t <template_path>] <zone_name>
    delete [--purge=vnic] <zone_name>
    edit [-i <image_uuid|image_path>] <zone_name>
    show [zone_name]
    list
    list-images [--refresh] [-b <brand>]
    start <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    console <zone_name>
    log <zone_name>
    help [-b <brand>]
    man
    version

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
