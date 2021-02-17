package Zadm::Image::OmniOSus;
use Mojo::Base 'Zadm::Image::OmniOS', -signatures;

use Mojo::URL;

has baseurl  => sub { Mojo::URL->new('https://us-west.mirror.omnios.org') };
# if we call shift->SUPER::baseurl here we'll initialise baseurl in the
# base class. if we don't explicitly call baseurl on the inherited class,
# postProcess (implemented in the base class) will pick up baseurl from
# the base class. bypass this by creating a new instance to get the baseurl.
has index    => sub { Mojo::URL->new('/media/img-us-west.json')->base(Zadm::Image::OmniOS->new->baseurl)->to_abs };
# overriding the provider as perl does not allow hyphens in package names
has provider => 'omnios-us';

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

S<Andy Fiddaman E<lt>andy@omnios.orgE<gt>>

=head1 HISTORY

2020-07-01 af Initial Version

=cut
