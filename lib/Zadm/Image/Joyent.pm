package Zadm::Image::Joyent;
use Mojo::Base 'Zadm::Image::base';

use Mojo::JSON qw(decode_json);

has baseurl  => 'https://images.joyent.com/images';
has index    => sub { shift->baseurl };

sub postProcess {
    my $self = shift;
    my $json = decode_json(shift) // [];

    return [
        map { {
            uuid   => $_->{uuid},
            name   => $_->{name},
            desc   => ($_->{description} =~ /^[^\s]+\s+(.+\.)\s+Built/)[0],
            vers   => $_->{version},
            img    => $self->baseurl . "/$_->{uuid}/file",
            brand  => 'lx',
            comp   => $_->{files}->[0]->{compression},
            kernel => $_->{tags}->{'kernel-version'},
            chksum => {
                digest => 'sha1',
                chksum => $_->{files}->[0]->{sha1},
            }
        } }
        grep { $_->{type} eq 'lx-dataset' }
        @$json
    ];
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
