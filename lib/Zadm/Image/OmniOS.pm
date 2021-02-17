package Zadm::Image::OmniOS;
use Mojo::Base 'Zadm::Image::base', -signatures;

use Mojo::JSON qw(decode_json);
use Mojo::URL;

has baseurl  => sub { Mojo::URL->new('https://downloads.omnios.org') };
has index    => sub($self) { Mojo::URL->new('/media/img.json')->base($self->baseurl)->to_abs };

sub postProcess($self, $json) {
    my $data = decode_json($json);

    return [
        map { {
            uuid   => $_->{uuid},
            name   => $_->{name},
            desc   => $_->{description},
            vers   => $_->{version},
            img    => Mojo::URL->new("/media/$_->{path}")->base($self->baseurl)->to_abs,
            brand  => $_->{brand},
            type   => $_->{type},
            comp   => $_->{comp},
            ext    => ($_->{brand} eq 'lx' ? '.tar.' : '.') . $_->{comp},
            chksum => {
                digest => 'sha256',
                chksum => $_->{sha256},
            }
        } }
        @{$data->{images} // []}
    ];
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
