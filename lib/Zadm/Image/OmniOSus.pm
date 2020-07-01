package Zadm::Image::OmniOSus;
use Mojo::Base 'Zadm::Image::OmniOS';

has baseurl  => 'https://us-west.mirror.omniosce.org/downloads/media';
has index    => sub { shift->SUPER::baseurl . '/img-us-west.json' };
# overriding the provider as perl does not allow hyphens in package names
has provider => 'omnios-us';

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

S<Andy Fiddaman E<lt>andy@omnios.orgE<gt>>

=head1 HISTORY

2020-07-01 af Initial Version

=cut
