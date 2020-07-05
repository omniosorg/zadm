package Zadm::Validator;
use Mojo::Base -base;

use Mojo::Log;
use Mojo::Exception;
use File::Basename qw(dirname);
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

my %unitFactors = (
    b   => 1,
    k   => 1024,
    m   => 1024 ** 2,
    g   => 1024 ** 3,
    t   => 1024 ** 4,
    p   => 1024 ** 5,
    e   => 1024 ** 6,
);

# static private methods
my $numeric = sub {
    return shift =~ /^\d+$/;
};

my $toBytes = sub {
    my $size = shift;

    return 0 if !$size;

    my $suffixes = join '', keys %unitFactors;

    my ($val, $suf) = $size =~ /^([\d.]+)([$suffixes])?$/i
        or return 0;

    return int ($val * $unitFactors{lc ($suf || 'b')});
};

my $toDiskStruct = sub {
    my $disk = shift;

    # transform plain disk paths into disk structures
    return $disk && !ref $disk ? { path => $disk } : $disk;
};

my $checkBlockSize = sub {
    my $blkSize = shift;
    my $name    = shift;
    my $min     = shift;
    my $max     = shift;

    my $val = $toBytes->($blkSize)
        or return "$name '$blkSize' not valid";

    $val >= $toBytes->($min)
        or return "$name '$blkSize' not valid. Must be greater or equal than $min";
    $val <= $toBytes->($max)
        or return "$name '$blkSize' not valid. Must be less or equal than $max";
    ($val & ($val - 1))
        and return "$name '$blkSize' not valid. Must be a power of 2";

    return undef;
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
    my $msg  = shift // 'invalid value';

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

sub lxIP {
    my $self = shift;

    return sub {
        my $ip = shift;

        return undef if $ip eq 'dhcp';

        return $self->cidr->($ip);
    }
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

        return (grep { $_ eq $nic } @{$self->utils->getOverLink}) ? undef
            : "link '$nic' does not exist or is wrong type";
    }
}

sub zoneNic {
    my $self = shift;

    return sub {
        my ($name, $nic) = @_;

        # if global-nic is set we just check if the vnic name is valid
        return $name =~ /^\w+\d+$/ ? undef : 'not a valid vnic name'
            if $nic->{'global-nic'};

        # physical links are ok
        my $dladm = $self->utils->readProc('dladm', [ qw(show-phys -p -o link) ]);
        return undef if grep { $_ eq $nic } @$dladm;

        $dladm = $self->utils->readProc('dladm', [ (qw(show-vnic -p -o), join (',', @VNICATTR)) ]);

        for my $vnic (@$dladm) {
            my @vnicattr = split /:/, $vnic, scalar @VNICATTR;
            my %nicProps = map { $_ => $vnicattr[$self->vnicmap->{$_}] } @VNICATTR;
            next if $nicProps{link} ne $name;

            $nic->{over} && $nic->{over} ne $nicProps{over}
                && $self->log->warn("WARNING: vnic specified over '" . $nic->{over}
                    . "' but is over '" . $nicProps{over} . "'\n");

            delete $nic->{over};
            return undef;
        }

        # only reach here if vnic does not exist
        # get first global link if over is not given

        $nic->{over} = $self->utils->getOverLink->[0] if !exists $nic->{over};

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
            # TODO: need to re-validate blocksize, size and sparse here as we don't
            # know in which order they have been validated. i.e. if they have all been
            # validated already so it is ok to use them here
            # for now just returning undef (i.e. successful validation) as the properties
            # validator will return a specific error message already, but don't create a volume
            #
            # considering adding an option to Data::Processor to specify the validation order
            return undef if $disk->{blocksize} && $self->blockSize->($disk->{blocksize})
                || $disk->{size} && $self->regexp(qr/^\d+[bkmgtpe]$/i)->($disk->{size})
                || $disk->{sparse} && $self->elemOf(qw(true false))->($disk->{sparse});

            my @cmd = (qw(create -p),
                ($disk->{sparse} && $disk->{sparse} eq 'true' ? qw(-s) : ()),
                ($disk->{blocksize} ? ('-o', "volblocksize=$disk->{blocksize}") : ()),
                '-V', ($disk->{size} // '10G'), $path);

            local $@;
            eval {
                local $SIG{__DIE__};

                $self->utils->exec('zfs', \@cmd);

            };
            return $@ if $@;
        }
        else {
            my $props = $self->utils->getZfsProp($path, [ qw(volsize volblocksize refreservation) ]);

            # TODO: this is done in the transformer for size, still we don't know about the execution order
            $disk->{size} = $self->toInt->($disk->{size});

            $self->log->warn("WARNING: blocksize cannot be changed for existing disk '$path'")
                if $disk->{blocksize} && $toBytes->($disk->{blocksize}) != $toBytes->($props->{volblocksize});
            $self->log->warn("WARNING: sparse cannot be changed for existing disk '$path'")
                if $disk->{sparse} && $disk->{sparse} ne ($props->{refreservation} eq 'none' ? 'true' : 'false');

            my $diskSize    = $toBytes->($props->{volsize});
            my $newDiskSize = $toBytes->($disk->{size});

            if ($newDiskSize && $diskSize > $newDiskSize) {
                $self->log->warn("WARNING: cannot shrink disk '$path'");
            }
            elsif ($newDiskSize > $diskSize) {
                $self->log->debug("enlarging disk '$path' to $disk->{size}");

                $self->utils->exec('zfs', [ 'set', "volsize=$disk->{size}", $path ]);
            }
        }

        return undef;
    }
}

sub zonePath {
    my $self = shift;

    return sub {
        my $path   = shift // '';
        my $parent = dirname $path;

        open my $fh, '<', '/etc/mnttab'
            or Mojo::Exception->throw("ERROR: opening '/etc/mnttab' for reading: $!\n");

        while (<$fh>) {
            my (undef, $mnt, $type) = split /\s+/;
            next if $type ne 'zfs';

            return undef if $parent eq $mnt;
        }

        return "could not find parent dataset for '$path'. Make sure that '$parent' is a ZFS dataset";
    }
}

sub blockSize {
    my $self = shift;

    return sub {
        return $checkBlockSize->(shift, 'blocksize', '512', '128k');
    }
}

sub sectorSize {
    my $self = shift;

    return sub {
        my $secSize = shift // '';

        my ($logical, $physical) = $secSize =~ m!^([^/]+)(?:/([^/]+))?$!;

        # logical size must be provided
        my $check = $checkBlockSize->($logical, 'sectorsize (logical)', '512', '16k');
        return $check if $check;

        if ($physical) {
            $check = $checkBlockSize->($physical, 'sectorsize (physical)', '512', '16k');
            return $check if $check;

            return "logical sectorsize ($logical) must be less or equal than physical ($physical)"
                if $logical > $physical;
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

sub toInt {
    my $self = shift;

    return sub {
        my $value = shift;

        return $value if !$value;

        $value =~ s/\.\d+//;

        return $value;
    }
}

sub toBytes {
    my $self = shift;

    return sub {
        my $value = shift;

        return $value if !$value;

        return join '/', map { my $val = $_; $toBytes->($val) || $val } split m!/!, $value;
    }
}

sub toDiskStruct {
    my $self    = shift;
    my $isarray = shift;

    return sub {
        my $disk = $isarray ? $self->toArray->(shift) : shift;

        return ref $disk eq ref []
            ? [ map { $toDiskStruct->($_) } @$disk ]
            : $toDiskStruct->($disk);
    }
}

sub toArray {
    my $self = shift;

    return sub {
        my $elem = shift;

        return ref $elem eq ref [] ? $elem : [ $elem ];
    }
}

sub vnc {
    my $self  = shift;
    my $brand = shift;

    return sub {
        my $vnc = shift;

        return undef if $vnc =~ m!(?:^|,)unix[:=]/!;
        return $self->elemOf(qw(on off), $brand eq 'bhyve' ? qw(wait) : ())->($vnc);
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
