package Zadm::Privilege;

use strict;
use warnings;

use Exporter qw(import);
use Mojo::Log;
use Sun::Solaris::Privilege qw(:ALL);

# re-export CONSTANTS from Sun::Solaris::Privilege so consumers of this module
# don't require to also include Sun::Solaris::Privilege
my @constants    = @{$Sun::Solaris::Privilege::EXPORT_TAGS{CONSTANTS}};
our @EXPORT_OK   = (@constants, qw(privInit privSet));
our %EXPORT_TAGS = (CONSTANTS => \@constants);

my %PSETS = (
    default => 'basic,!file_link_any,!net_access,!proc_info,!proc_session',
    empty   => 'basic,!file_link_any,!file_read,!file_write,!net_access,!proc_exec,'
               . '!proc_fork,!proc_info,!proc_secflags,!proc_session',
);

my $log = Mojo::Log->new(level => $ENV{__ZADMDEBUG} ? 'debug' : 'warn');

my $getPrivSet = sub {
    my $set = shift // 'default';

    my $pstr = $PSETS{$set};

    # build target privileges
    my $targprivs = priv_str_to_set($pstr, ',');
    # We keep FILE_DAC_WRITE if the caller has it
    priv_addset($targprivs, PRIV_FILE_DAC_WRITE) if $set ne 'empty';

    # get the current permitted privileges
    my $curprivs = getppriv(PRIV_PERMITTED);

    # intersect the target set with current set to make sure
    # we only set permissions which are available to the caller
    my $pset = priv_intersect($curprivs, $targprivs);

    return $pset;
};

# public functions
sub privSet {
    my $opts  = shift || {};
    my @privs = @_;

    my $pset = $opts->{reset}                  ? $getPrivSet->('default')
             : $opts->{add} || $opts->{remove} ? priv_emptyset
             : $opts->{all}                    ? priv_fillset
             :                                   $getPrivSet->('empty');

    priv_addset($pset, $_) for @privs;

    my @sets = $opts->{inherit} ? (PRIV_EFFECTIVE, PRIV_INHERITABLE) : (PRIV_EFFECTIVE);
    if ($opts->{remove}) {
        $log->debug(q{Releasing effective privilege '}
            . priv_set_to_str($pset, ',', PRIV_STR_LIT) . q{'.});
        setppriv(PRIV_OFF, $_, $pset) for @sets;
    }
    elsif ($opts->{add}) {
        $log->debug(q{Acquiring effective privilege '}
            . priv_set_to_str($pset, ',', PRIV_STR_LIT) . q{'.});
        setppriv(PRIV_ON, $_, $pset) for @sets;
    }
    else {
        $log->debug(q{Setting effective privileges to '}
            . priv_set_to_str($pset, ',',
            $opts->{all} || $opts->{reset} ? PRIV_STR_PORT : PRIV_STR_LIT) . q{'.});
        setppriv(PRIV_SET, $_, $pset) for @sets;
    }

    if ($opts->{lock}) {
        my $eset = getppriv(PRIV_EFFECTIVE);

        $log->debug('Locking privileges.');
        setppriv(PRIV_SET, $_, $eset) for qw(PRIV_PERMITTED PRIV_LIMIT);
    }
}

sub privInit {
    # enable privilege debugging globally
    setpflags(PRIV_DEBUG, 1) if $ENV{__ZADMDEBUG};

    privSet({ reset => 1 });
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

2021-04-24 had Initial Version

=cut
