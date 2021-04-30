# stub package to make GitHub actions happy
package Sun::Solaris::Privilege;

use Exporter qw(import);

use constant {
    PRIV_DEBUG          => 1,
    PRIV_EFFECTIVE      => 'Effective',
    PRIV_FILE_DAC_WRITE => 'file_dac_write',
    PRIV_INHERITABLE    => 'Inheritable',
    PRIV_LIMIT          => 'Limit',
    PRIV_PERMITTED      => 'Permitted',
    PRIV_SET            => 2,
    PRIV_STR_LIT        => 1,
    PRIV_STR_PORT       => 0,
};

my @constants = qw(PRIV_DEBUG PRIV_EFFECTIVE PRIV_FILE_DAC_WRITE PRIV_INHERITABLE
    PRIV_LIMIT PRIV_PERMITTED PRIV_SET PRIV_STR_LIT PRIV_STR_PORT);

our @EXPORT_OK = (@constants, qw(getppriv priv_addset priv_intersect priv_set_to_str
    priv_str_to_seti setpflags setppriv));
our %EXPORT_TAGS = (ALL => \@EXPORT_OK, CONSTANTS => \@constants);

sub getppriv { }
sub priv_addset { }
sub priv_intersect { }
sub priv_set_to_str { }
sub priv_str_to_set { }
sub setpflags { }
sub setppriv { }

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

2021-04-25 had Initial Version

=cut
