package Zadm::Zone::KVM;
use Mojo::Base 'Zadm::Zone::base';

use Mojo::Exception;
use IO::Socket::UNIX qw(SOCK_STREAM);
use IO::Select;
use Regexp::IPv4 qw($IPv4_re);
use Regexp::IPv6 qw($IPv6_re);

# gobals
my $ZVOLDEV  = '/dev/zvol/rdsk';
my $ZVOLRX   = qr!/dev/zvol/r?dsk/!;
my @MON_INFO = qw(block blockstats chardev cpus kvm network pci registers qtree usb version vnc);
my $RCV_TMO  = 3;

# private static methods
my $cpuCount = sub {
    my $vcpus = shift;

    return $vcpus if !$vcpus || $vcpus =~ /^\d+$/;

    my %cpu = map { /^([^=]+)=([^=]+)$/ } split ',', $vcpus;

    return join '/', map { $cpu{$_} // '1' } qw(sockets cores threads);
};

has template => sub {
    my $self = shift;
    my $name = $self->name;

    my $template = $self->SUPER::template;
    # KVM and derived zones do not have 'dns-domain' or 'resolvers' properties; drop them
    delete $template->{$_} for qw(dns-domain resolvers);

    return {
        %$template,
        bootdisk    => {
            path        => "rpool/$name/root",
            size        => "10G",
            sparse      => 'false',
            blocksize   => '8k',
        },
        ram         => '2G',
        vcpus       => '4',
        vnc         => 'on',
    }
};
has options => sub {
    {
        create  => {
            image => {
                getopt => 'image|i=s',
            },
        },
        install => {
            image => {
                getopt => 'image|i=s',
            },
        },
    }
};
has monsocket => sub { shift->config->{zonepath} . '/root/tmp/vm.monitor' };
has vncsocket => sub {
    my $self = shift;

    my ($socket) = $self->config->{vnc} =~ m!^unix[:=](/[^, ]+)!;

    return $self->config->{zonepath} . '/root' . ($socket || '/tmp/vm.vnc');
};
has public    => sub { [ qw(reset nmi vnc monitor) ] };
has diskattr  => sub {
    my $self = shift;

    my %diskattr;
    for my $type (qw(disk bootdisk)) {
        $diskattr{$type} = {
            map  { $_ => $self->schema->{$type}->{members}->{$_}->{'x-dskattr'} }
            grep { exists $self->schema->{$type}->{members}->{$_}->{'x-dskattr'} }
            keys %{$self->schema->{$type}->{members}}
        };
    };

    return \%diskattr;
};
# adding an instance specific attribute to store the bootdisk path to be used by install
has bootdisk => sub { {} };

my $queryMonitor = sub {
    my $self   = shift;
    my $query  = shift;
    my $nowait = shift;

    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $self->monsocket,
    ) or Mojo::Exception->throw("Cannot open socket $!\n");

    $socket->send($query);

    return if $nowait;

    my $wait = IO::Select->new;
    $wait->add($socket);

    my $recv;
    while ($wait->can_read($RCV_TMO)){
        my $buffer;

        defined $socket->recv($buffer, 1024)
            or Mojo::Exception->throw("ERROR: cannot read from monitor: $!\n");
        $recv .= $buffer;

        last if $recv =~ s/\(qemu\)/\(qemu\)/g == 2;
    }

    $socket->close();
    return [ grep { $_ !~ /^(?:QEMU|\(qemu\))/ } split /[\r\n]+/, $recv ];
};

my $getDiskAttr = sub {
    my $self = shift;
    my $attr = shift;

    return {} if !$attr;

    return {
        map {
            my ($key, $val) = split /=/, $_, 2;

            $key => $val // 'true'
        } split ',', $attr
    };
};

my $setDiskAttr = sub {
    my $self = shift;
    my $type = shift;
    my $disk = shift // {};

    my $attrstr = '';

    for my $attr (keys %{$self->diskattr->{$type}}) {
        $attrstr .= !$disk->{$attr}                   ? ''
                  # boolean attr handling
                  : $self->diskattr->{$type}->{$attr} ? ($disk->{$attr} eq 'true' ? ",$attr" : '')
                  # non-boolean attr handling
                  :                                     ",$attr=$disk->{$attr}";
    }

    return $attrstr;
};

my $getDiskProps = sub {
    my $self = shift;
    my ($zvol, $attrstr) = split /,/, shift, 2;

    my $attr = $self->$getDiskAttr($attrstr);

    # TODO: /dev... needs to be removed here already so zvol properties can be queried
    # this is also done in the transformer as well as the validator
    $zvol =~ s|^/dev/zvol/r?dsk/||;

    my $props = $self->utils->getZfsProp($zvol, [ qw(volsize volblocksize refreservation) ]);

    # TODO: extract defaults from schema
    return {
        path        => $zvol,
        size        => $props->{volsize} // '10G',
        blocksize   => $props->{volblocksize} // '8K',
        sparse      => ($props->{refreservation} // '') eq 'none' ? 'true' : 'false',
        %$attr,
    };
};

sub getPostProcess {
    my $self = shift;
    my $cfg  = shift;

    my $disk;
    $cfg->{disk} = [];
    # handle disks before the default getPostProcess
    if ($cfg->{attr} && ref $cfg->{attr} eq ref []) {
        for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
            my ($boot, $index) = $cfg->{attr}->[$i]->{name} =~ /^(boot)?disk(\d+)?$/
                or next;

            if (defined $index) {
                $cfg->{disk}->[$index] = $self->$getDiskProps($cfg->{attr}->[$i]->{value});
            }
            elsif (defined $boot) {
                $cfg->{bootdisk} = $self->$getDiskProps($cfg->{attr}->[$i]->{value});
            }
            else {
                $disk = $self->$getDiskProps($cfg->{attr}->[$i]->{value});
            }
            splice @{$cfg->{attr}}, $i, 1;
        }
    }

    # add disk w/o index to the first available slot
    if ($disk) {
        # let it overrun here by 1 on purpose so we find a slot for disk
        for (my $i = 0; $i <= @{$cfg->{disk}}; $i++) {
            if (!$cfg->{disk}->[$i]) {
                $cfg->{disk}->[$i] = $disk;
                last;
            }
        }
    }

    $cfg->{cdrom} = [];
    # handle cdroms before the default getPostProcess
    if ($cfg->{attr} && ref $cfg->{attr} eq ref []) {
        for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
            my ($index) = $cfg->{attr}->[$i]->{name} =~ /^cdrom(\d+)?$/
                or next;

            # TODO: this can be changed once we drop support for r30/r32
            # since they only support a single cdrom we place the cdrom w/o index
            # in slot 0; this could overwrite cdrom0 if it was manually added
            $index //= 0;
            $cfg->{cdrom}->[$index] = $cfg->{attr}->[$i]->{value};
            splice @{$cfg->{attr}}, $i, 1;
        }
    }

    $cfg = $self->SUPER::getPostProcess($cfg);

    # remove cdrom lofs mount from config
    if ($cfg->{cdrom} && ref $cfg->{cdrom} eq ref [] && $cfg->{fs} && ref $cfg->{fs} eq ref []) {
        for (my $i = $#{$cfg->{fs}}; $i >= 0; $i--) {
            splice @{$cfg->{fs}}, $i, 1
                # cdroms are indexed and there might be empty slots
                if grep { $_ && $_ eq $cfg->{fs}->[$i]->{special} } @{$cfg->{cdrom}};
        }
    }

    # remove device for bootdisk
    $cfg->{device} = [ grep { $_->{match} !~ m!^(?:$ZVOLRX)?$cfg->{bootdisk}->{path}$! } @{$cfg->{device}} ]
        if (exists $cfg->{bootdisk} && ref $cfg->{bootdisk} eq ref {} && $cfg->{device} && ref $cfg->{device} eq ref []);

    # remove device for disk
    if ($cfg->{disk} && ref $cfg->{disk} eq ref [] && $cfg->{device} && ref $cfg->{device} eq ref []) {
        for (my $i = $#{$cfg->{device}}; $i >= 0; $i--) {
            splice @{$cfg->{device}}, $i, 1
                # disks are indexed and there might be empty slots
                if grep { $_ && ref $_ eq ref {} && $cfg->{device}->[$i]->{match} =~ m!^(?:$ZVOLRX)?$_->{path}$! } @{$cfg->{disk}};
        }

    }

    # remove fs/device/disk/cdrom if empty
    $cfg->{$_} && ref $cfg->{$_} eq ref [] && !@{$cfg->{$_}} && delete $cfg->{$_} for qw(fs device disk cdrom);

    return $cfg;
}

sub setPreProcess {
    my $self = shift;
    my $cfg  = shift;

    # add cdrom lofs mount to zone config
    if ($cfg->{cdrom} && ref $cfg->{cdrom} eq ref []) {
        for (my $i = 0; $i < @{$cfg->{cdrom}}; $i++) {
            next if !$cfg->{cdrom}->[$i];

            push @{$cfg->{attr}}, {
                # cdrom0 shall be just cdrom
                name    => 'cdrom' . ($i || ''),
                type    => 'string',
                value   => $cfg->{cdrom}->[$i],
            };

            push @{$cfg->{fs}}, {
                dir     => $cfg->{cdrom}->[$i],
                options => [ qw(ro nodevices) ],
                special => $cfg->{cdrom}->[$i],
                type    => 'lofs',
            };
        }

        delete $cfg->{cdrom};
    }

    # add device for bootdisk
    $self->bootdisk({});
    if ($cfg->{bootdisk}) {
        my $disksize = $cfg->{bootdisk}->{size};
        my $diskattr = $self->$setDiskAttr('bootdisk', $cfg->{bootdisk});

        $cfg->{bootdisk} = $cfg->{bootdisk}->{path};
        $cfg->{bootdisk} =~ s!^$ZVOLRX!!;
        $self->bootdisk(
            {
                path => $cfg->{bootdisk},
                size => $disksize,
            }
        );
        push @{$cfg->{device}}, { match => "$ZVOLDEV/$cfg->{bootdisk}" };
        $cfg->{bootdisk} .= $diskattr;

    }

    # handle disks
    if ($cfg->{disk} && ref $cfg->{disk} eq ref []) {
        for (my $i = 0; $i < @{$cfg->{disk}}; $i++) {
            next if !$cfg->{disk}->[$i] || (ref $cfg->{disk}->[$i] eq ref {} && !%{$cfg->{disk}->[$i]});

            my $disk = $cfg->{disk}->[$i]->{path};
            $disk =~ s!^$ZVOLRX!!;

            push @{$cfg->{attr}}, {
                name    => "disk$i",
                type    => 'string',
                value   => $disk . $self->$setDiskAttr('disk', $cfg->{disk}->[$i]),
            };

            push @{$cfg->{device}}, { match => "$ZVOLDEV/$disk" };
        }

        delete $cfg->{disk};
    }

    return $self->SUPER::setPreProcess($cfg);
}

sub install {
    my $self = shift;

    # just install the zone if no image was provided for the bootdisk
    return $self->SUPER::install
        if !$self->opts->{image};

    %{$self->bootdisk} || do {
        $self->log->warn('WARNING: no bootdisk specified. Not installing image');
        return $self->SUPER::install;
    };

    # image can be either for kvm or bhyve
    my $img = $self->zones->image->getImage($self->opts->{image}, qr/kvm|bhyve/);

    $img->{_file} && -r $img->{_file} || do {
        $self->log->warn('WARNING: no valid image path given. Not installing image');
        return $self->SUPER::install;
    };

    # TODO: is there a better way of handling this?
    my $check;
    if (!$self->utils->isaTTY || $ENV{__ZADMTEST}) {
        $check = 'yes';
    }
    else {
        print "Going to overwrite the bootdisk '" . $self->bootdisk->{path}
            . "'\nwith the provided image. Do you want to continue [Y/n]? ";
        chomp ($check = <STDIN>);
    }

    if ($check !~ /^no?$/i) {
        $self->utils->zfsRecv($img->{_file}, $self->bootdisk->{path});
        # TODO: '-x volsize' for zfs recv seems not to work so we must reset the
        # volsize to the original value after receive
        $self->utils->exec('zfs', [ 'set', 'volsize=' . $self->bootdisk->{size}, $self->bootdisk->{path} ]);

        $self->SUPER::install;
    }
}

sub poweroff {
    my $self = shift;

    $self->$queryMonitor("quit\n", 1);

    # make sure parent class does 'halt'
    $self->SUPER::poweroff;
}

sub reset {
    shift->$queryMonitor("system_reset\n", 1);
}

sub nmi {
    shift->$queryMonitor("nmi 0\n", 1);
}

sub vnc {
    my $self   = shift;
    my $listen = shift // '5900';

    $self->log->warn('WARNING: zone ' . $self->name . " is not running\n")
        if !$self->is('running');
    Mojo::Exception->throw('ERROR: vnc is not set-up for zone ' . $self->name . "\n")
        if !$self->config->{vnc} || $self->config->{vnc} eq 'off';

    my ($ip, $port) = $listen =~ /^(?:($IPv4_re|$IPv6_re):)?(\d+)$/;
    Mojo::Exception->throw("ERROR: port '$port' is not valid\n")
        if !$port;
    $ip //= '127.0.0.1';

    $self->log->debug("VNC proxy listening on: $ip:$port");

    print 'VNC server for zone ' . $self->name . " console started on $ip:$port\n";
    $self->utils->exec('socat', [ "TCP-LISTEN:$port,bind=$ip,reuseaddr,fork",
        'UNIX-CONNECT:' . $self->vncsocket ]);
}

sub monitor {
    my $self = shift;

    $self->utils->exec('nc', [ '-U', $self->monsocket ],
        'cannot access monitor socket ' . $self->monsocket);
}

sub zStats {
    my $self = shift;

    return {
        %{$self->SUPER::zStats},
        RAM  => $self->config->{ram} // '-',
        CPUS => $cpuCount->($self->config->{vcpus})
            // $self->config->{'capped-cpu'}->{ncpus} // '1',
    };
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
    show [zone_name [property]]
    list
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    brands
    start [-c [extra_args]] <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    console [extra_args] <zone_name>
    monitor <zone_name>
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
