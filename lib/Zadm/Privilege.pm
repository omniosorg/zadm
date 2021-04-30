package Zadm::Privilege;

use strict;
use warnings;

use Exporter qw(import);
use Mojo::Log;
use Sun::Solaris::Privilege qw(:ALL);

# re-export CONSTANTS from Sun::Solaris::Privilege so consumers of this module
# don't require to also include Sun::Solaris::Privilege
my @constants    = @{$Sun::Solaris::Privilege::EXPORT_TAGS{CONSTANTS}};
our @EXPORT_OK   = (@constants, qw(privInit privSet privReset));
our %EXPORT_TAGS = (CONSTANTS => \@constants);

# defining the permitted privileges here for each (command depending) code path
# commands not defined here will use __default. individual blocks can then
# still be privilege bracketed where it seems appropriate to be more restrictive
my %PLIMIT = (
    __default     => 'basic,!file_link_any,!net_access,!proc_info,!proc_secflags,!proc_session',
    __empty       => 'basic,!file_link_any,!file_read,!file_write,!net_access,!proc_exec,'
                   . '!proc_fork,!proc_info,!proc_secflags,!proc_session',
    boot          => 'all', # booting a zone currently requires a full set
    console       => 'all', # attaching to a zone's console currently requires a full set
    create        => 'basic,sys_mount,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    edit          => 'basic,sys_mount,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    halt          => 'all', # halting a zone currently requires a full set
    install       => 'basic,sys_mount,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    'list-images' => 'basic,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    login         => 'all', # login to a zone currently requires a full set
    pull          => 'basic,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    reboot        => 'all', # rebooting a zone currently requires a full set
    shutdown      => 'all', # shutting down a zone currently requires a full set
    vnc           => 'basic,priv_net_privaddr,!file_link_any,!proc_info,!proc_secflags,!proc_session',
    webvnc        => 'basic,priv_net_privaddr,!file_link_any,!proc_info,!proc_secflags,!proc_session',
);

my %ALIASMAP = (
    start    => 'boot',
    stop     => 'shutdown',
    poweroff => 'halt',
    restart  => 'reboot',
    reset    => 'halt',
);

my $log = Mojo::Log->new(level => $ENV{__ZADMDEBUG} ? 'debug' : 'warn');

my $getPrivSet = sub {
    my $cmd = shift // '';

    my $pstr = exists $PLIMIT{$cmd}   ? $PLIMIT{$cmd}
             : exists $ALIASMAP{$cmd} ? $PLIMIT{$ALIASMAP{$cmd}}
             :                          $PLIMIT{__default};

    # build target privileges
    my $targprivs = priv_str_to_set($pstr, ',');
    # We keep FILE_DAC_WRITE if the caller has it
    priv_addset($targprivs, PRIV_FILE_DAC_WRITE) if $cmd ne '__empty';

    # get the current permitted privileges
    my $curprivs = getppriv(PRIV_PERMITTED);

    # intersect the target set with current set to make sure
    # we only set permissions which are available to the caller
    my $pset = priv_intersect($curprivs, $targprivs);

    return $pset;
};

# public functions
sub privInit {
    my $cmd = shift // '';

    # enable privilege debugging globally
    setpflags(PRIV_DEBUG, 1) if $ENV{__ZADMDEBUG};

    my $pset = $getPrivSet->($cmd);

    $log->debug(q{Setting permitted privileges to '}
        . priv_set_to_str($pset, ',', PRIV_STR_PORT) . q{'.});
    setppriv(PRIV_SET, $_, $pset) for (PRIV_PERMITTED, PRIV_LIMIT, PRIV_INHERITABLE);
}

sub privSet {
    my @privs = @_;

    my $pset = $getPrivSet->('__empty');
    priv_addset($pset, $_) for @privs;

    $log->debug(q{Setting effective privileges to '}
        . priv_set_to_str($pset, ',', PRIV_STR_LIT) . q{'.});
    setppriv(PRIV_SET, PRIV_EFFECTIVE, $pset)
}

sub privReset {
    my $pset = getppriv(PRIV_PERMITTED);

    $log->debug("Setting effective privileges to permitted.");
    setppriv(PRIV_SET, PRIV_EFFECTIVE, $pset);
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
