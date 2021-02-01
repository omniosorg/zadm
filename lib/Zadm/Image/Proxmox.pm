package Zadm::Image::Proxmox;
use Mojo::Base 'Zadm::Image::base', -signatures;

use Mojo::URL;

has baseurl  => sub { Mojo::URL->new('http://download.proxmox.com') };
has index    => sub($self) { Mojo::URL->new('/images/aplinfo.dat')->base($self->baseurl)->to_abs };

sub postProcess($self, $text = '') {
    my @imgs;
    for my $img (split /(?:\r?\n){2}/, $text) {
        my %img = map { split /:\s+/, $_, 2 }
                  map { local $_ = $_; s/\r?\n\s+/ /g; $_ }
                  split /\r?\n(?!\s+)/, $img;

        # skip incomplete packages
        next if !$img{Version} || !$img{Location};

        push @imgs, {
            # proxmox does not provide a uuid, so we'll use md5sum
            uuid   => $img{md5sum},
            name   => $img{Package},
            desc   => $img{Description},
            vers   => $img{Version},
            img    => Mojo::URL->new("/images/$img{Location}")->base($self->baseurl)->to_abs,
            brand  => 'lx',
            comp   => 'gzip',
            ext    => '.tar.gz',
            # we provide a default kernel version of 4.4
            kernel => '4.4',
            chksum => {
                digest => 'sha512sum',
                chksum => $img{sha512sum},
            },
        };
    }

    return \@imgs;
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
