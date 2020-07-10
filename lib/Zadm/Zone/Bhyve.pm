package Zadm::Zone::Bhyve;
use Mojo::Base 'Zadm::Zone::KVM';

# reset public interface as the inherited list
# from KVM will have additional methods
has public => sub { [ qw(nmi vnc) ] };

my $bhyveCtl = sub {
    my $self = shift;
    my $cmd  = shift;

    my $name = $self->name;

    $self->is('running') || do {
        $self->log->warn("WARNING: cannot '$cmd' $name. "
            . "$name is not in running state.");
        return 0;
    };

    $self->utils->exec('bhyvectl', [ "--vm=$name", $cmd ],
        "cannot $cmd zone $name");
};

sub poweroff {
    shift->$bhyveCtl('--force-poweroff');
}

sub reset {
    shift->$bhyveCtl('--force-reset');
}

sub nmi {
    shift->$bhyveCtl('--inject-nmi');
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid|image_path>] [-t <template_path>] <zone_name>
    delete [--purge=vnic] <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-i <image_uuid|image_path>] [-f] <zone_name>
    uninstall <zone_name>
    show [zone_name [property]]
    list
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    brands
    start [-c [extra_args]] <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    nmi <zone_name>
    console [extra_args] <zone_name>
    vnc [<[bind_addr:]port>] <zone_name>
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
