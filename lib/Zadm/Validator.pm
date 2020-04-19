package Zadm::Validator;
use Mojo::Base -base;

use Mojo::Log;
use Regexp::IPv4 qw($IPv4_re);
use Regexp::IPv6 qw($IPv6_re);

use Zadm::Utils;

# constants
my @VNICATTR = qw(link over vid);

my %vcpuOptions = (
    sockets => undef,
    cores   => undef,
    threads => undef,
    maxcpus => undef,
);

# private methods
my $getPhys = sub {
    my $self = shift;

    my $dladm = $self->utils->pipe('dladm', [ qw(show-phys -p -o link) ]);

    chomp (my @phys = (<$dladm>));

    return \@phys;
};

# static private methods
my $numeric = sub {
	return shift =~ /^\d+$/;
};

# attributes
has log   => sub { Mojo::Log->new(level => 'debug') };
has utils => sub { Zadm::Utils->new(log => shift->log) };

has vnicmap => sub {
    my $i = 0;
    return { map { $_ => $i++ } @VNICATTR };
};

sub regexp {
    my $self = shift;
    my $rx   = shift;
    my $msg  = shift;

    return sub {
        my $value = shift;
        return $value =~ /$rx/ ? undef : "$msg ($value)";
    }
}

sub elemOf {
    my $self = shift;
    my $elems = [ @_ ];

    return sub {
        my $value = shift;
        return (grep { $_ eq $value } @$elems) ? undef
            : 'expected a value from the list: ' . join(', ', @$elems);
    }
}

sub bool {
    return shift->elemOf(qw(true false));
}

sub ipv4 {
    return shift->regexp(qr/^$IPv4_re$/, 'not a valid IPv4 address');
}

sub ipv6 {
    return shift->regexp(qr/^$IPv6_re$/, 'not a valid IPv6 address');
}

sub ip {
    return shift->regexp(qr/^(?:$IPv4_re|$IPv6_re)$/, 'not a valid IP address');
}

sub cidrv4 {
    return shift->regexp(qr!^$IPv4_re/\d{1,2}$!, 'not a valid IPv4 CIDR address');
}

sub cidrv6 {
    return shift->regexp(qr!^$IPv6_re/\d{1,3}$!, 'not a valid IPv6 CIDR address');
}

sub cidr {
    return shift->regexp(qr!^(?:$IPv4_re/\d{1,2}|$IPv6_re/\d{1,3})$!, 'not a valid CIDR address');
}

sub macaddr {
    return shift->regexp(qr/^(?:[\da-f]{1,2}:){5}[\da-f]{1,2}$/i, 'not a valid MAC address');
}

sub file {
    my $self = shift;
    my $op   = shift;
    my $msg  = shift;

    return sub {
        my $file = shift;
        return open (my $fh, $op, $file) ? undef : "$msg $file: $!";
    }
}

sub physical {
    my $self = shift;

    return sub {
        my $nic = shift;

        return (grep { $_ eq $nic } @{$self->$getPhys}) ? undef
            : "physical link '$nic' does not exist";
    }
}

sub globalNic {
    my $self = shift;

    return sub {
        my $nic = shift;
        my $net = shift;

        return $net->{'allowed-address'} ? undef : 'allowed-address must be set when global-nic is auto'
            if $nic eq 'auto';

        return (grep { $_ eq $nic } @{$self->$getPhys}) ? undef
            : "physical link '$nic' does not exist";
    }
}

sub vnic {
    my $self = shift;

    return sub {
        my ($name, $nic) = @_;

        # if global-nic is set we just check if the vnic name is valid
        return $name =~ /^\w+\d+$/ ? undef : 'not a valid vnic name'
            if $nic->{'global-nic'};

        my $dladm = $self->utils->pipe('dladm', [ (qw(show-vnic -p -o), join (',', @VNICATTR)) ]);

        my $vnicmap = $self->vnicmap;
        while (my $vnic = <$dladm>) {
            chomp $vnic;
            my %nicProps = map { $_ => (split /:/, $vnic, scalar keys %$vnicmap)[$vnicmap->{$_}] } @VNICATTR;
            next if $nicProps{link} ne $name;

            $nic->{over} && $nic->{over} ne $nicProps{over}
                && $self->log->warn("WARNING: vnic specified over '" . $nic->{over}
                    . "' but is over '" . $nicProps{over} . "'\n");

            return undef;
        }

        # only reach here if vnic does not exist
        # get first physical link if over is not given

        $nic->{over} = $self->$getPhys->[0] if !exists $nic->{over};

        # TODO: add exception handling and return error string instead
        $self->utils->exec('dladm', [ (qw(create-vnic -l), $nic->{over}, $name) ]);

        # TODO: vnic handling. do we support over?
        delete $nic->{over};

        return undef;
    }
}

sub vcpus {
    my $self = shift;

    return sub {
        my $vcpu = shift;

        return undef if $numeric->($vcpu);

        my @vcpu = split ',', $vcpu;

        shift @vcpu if $numeric->($vcpu[0]);

        for my $vcpuConf (@vcpu){
            my @vcpuConf = split '=', $vcpuConf, 2;
            exists $vcpuOptions{$vcpuConf[0]} && $numeric->($vcpuConf[1])
                or return "ERROR: vcpu setting not valid";
        }

        return undef;
    }
}

sub zvol {
    my $self = shift;

    return sub {
        my ($path, $disk) = @_;

        $path =~ s|^/dev/zvol/r?dsk/||;

        if (!-e "/dev/zvol/rdsk/$path") {
            my @cmd = (qw(create -p), '-V', ($disk->{disk_size} // '10G'), $path);

            # TODO: add exception handling and return error string instead
            $self->utils->exec('zfs', \@cmd);
        }

        return undef;
    }
}

sub stripDev {
    my $self = shift;

    return sub {
        my $path = shift;

        $path =~ s|^/dev/zvol/r?dsk/||;
        # resources don't like multiple forward slashes, remove them
        $path =~ s|/{2,}|/|g;

        return $path;
    }
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
