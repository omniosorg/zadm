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
my $getOverLink = sub {
    my $self = shift;

    chomp (my @int = map {
        my $dladm = $self->utils->pipe('dladm', [ "show-$_", qw(-p -o link) ]); (<$dladm>)
    } qw(phys etherstub overlay));

    return \@int;
};

# static private methods
my $numeric = sub {
    return shift =~ /^\d+$/;
};

my $calcBlkSize = sub {
    my $blkSize = shift;

    my ($val, $suf) = $blkSize =~ /^(\d+)(k?)$/i
        or return undef;

    return $suf ? $val * 1024 : $val;
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

sub globalNic {
    my $self = shift;

    return sub {
        my $nic = shift;
        my $net = shift;

        return $net->{'allowed-address'} ? undef : 'allowed-address must be set when global-nic is auto'
            if $nic eq 'auto';

        return (grep { $_ eq $nic } @{$self->$getOverLink}) ? undef
            : "link '$nic' does not exist or is wrong type";
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

            delete $nic->{over};
            return undef;
        }

        # only reach here if vnic does not exist
        # get first global link if over is not given

        $nic->{over} = $self->$getOverLink->[0] if !exists $nic->{over};

        local $@;
        eval {
            local $SIG{__DIE__};

            $self->utils->exec('dladm', [ (qw(create-vnic -l), $nic->{over}, $name) ]);
        };
        return $@ if $@;

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
            # TODO: need to re-validate block_size, disk_size and sparse here as we don't
            # know in which order they have been validated. i.e. if they have all been
            # validated already so it is ok to use them here
            # for now just returning undef (i.e. successful validation) as the properties
            # validator will return a specific error message already, but don't create a volume
            #
            # considering adding an option to Data::Processor to specify the validation order
            return undef if $disk->{block_size} && $self->blockSize->($disk->{block_size})
                || $disk->{disk_size} && $self->regexp(qr/^\d+[bkmgtpe]$/i)->($disk->{disk_size})
                || $disk->{sparse} && $self->elemOf(qw(true false))->($disk->{sparse});

            my @cmd = (qw(create -p),
                ($disk->{sparse} eq 'true' ? qw(-s) : ()),
                ($disk->{block_size} ? ('-o', "volblocksize=$disk->{block_size}") : ()),
                '-V', ($disk->{disk_size} // '10G'), $path);

            local $@;
            eval {
                local $SIG{__DIE__};

                $self->utils->exec('zfs', \@cmd);

            };
            return $@ if $@;
        }

        return undef;
    }
}

sub blockSize {
    my $self = shift;

    return sub {
        my $blkSize = shift;

        my $val = $calcBlkSize->($blkSize)
            or return "block_size '$blkSize' not valid";

        $val >= 512
            or return "block_size '$blkSize' not valid. Must be greater or equal than 512";
        $val <= 128 * 1024
            or return "block_size '$blkSize' not valid. Must be less or equal than 128k";
        ($val & ($val - 1))
            and return "block_size '$blkSize' not valid. Must be a power of 2";

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
