package Zadm::Zone::KVM;
use Mojo::Base 'Zadm::Zone::base', -signatures;

use Mojo::Exception;
use Mojo::File;
use IO::Socket::UNIX qw(SOCK_STREAM);
use IO::Select;
use Regexp::IPv4 qw($IPv4_re);
use Regexp::IPv6 qw($IPv6_re);
use Zadm::Privilege qw(:CONSTANTS privSet);

# gobals
my $ZVOLDEV  = '/dev/zvol/rdsk';
my $ZVOLRX   = qr!/dev/zvol/r?dsk/!;
my @MON_INFO = qw(block blockstats chardev cpus kvm network pci registers qtree usb version vnc);
my $RCV_TMO  = 3;

# private static methods
my $cpuCount = sub($vcpus, $raw = 0) {
    return $vcpus if !$vcpus || $vcpus =~ /^\d+$/;

    my %cpu = map { /^([^=]+)=([^=]+)$/ } split /,/, $vcpus;

    return \%cpu if $raw;
    return join '/', map { $cpu{$_} // '1' } qw(sockets cores threads);
};

my $getIPPort = sub($self, $listen) {
    $self->log->warn('WARNING: zone', $self->name, 'is not running')
        if !$self->is('running');

    Mojo::Exception->throw('ERROR: vnc is not set up for zone ' . $self->name . "\n")
        if !$self->utils->boolIsTrue($self->config->{vnc});

    my ($ip, $port) = $listen =~ /^(?:(\*|$IPv4_re|(?:\[?(?:$IPv6_re|::)\]?)):)?(\d+)$/;
    Mojo::Exception->throw("ERROR: '$listen' is not valid\n") if !$port;
    $ip = $self->utils->gconf->{VNC}->{bind_address} || '127.0.0.1' if !$ip;
    $ip = '[::]' if $ip eq '*';

    return ($ip, $port);
};

# attributes
has template => sub($self) {
    my $name = $self->name;

    my $template = $self->SUPER::template;

    # KVM brand does not support 'dns-domain' or 'resolvers' properties;
    # but derived brands do
    if ($self->brand eq 'kvm') {
        delete $template->{$_} for qw(dns-domain resolvers);
    }

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
        vnc     => {
            web   => {
                getopt => 'web|w',
            },
        },
    }
};
has monsocket => sub($self) { Mojo::File->new($self->config->{zonepath}, 'root/tmp/vm.monitor') };
has vncsocket => sub($self) {
    my ($socket) = $self->config->{vnc} =~ m!^unix[:=]/([^, ]+)!;

    return Mojo::File->new($self->config->{zonepath}, 'root', ($socket || 'tmp/vm.vnc'));
};
has public    => sub { [ qw(nmi vnc webvnc monitor) ] };
has diskattr  => sub($self) {
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
# install image can be either for kvm or bhyve
has ibrand   => sub { qr/kvm|bhyve/ };

has beaware  => 0;
has rootds   => sub($self) { $self->config->{bootdisk}->{path} };

# private methods
my $queryMonitor = sub($self, $query, $nowait = 0) {
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

my $getDiskAttr = sub($self, $attr) {
    return {} if !$attr;

    return {
        map {
            my ($key, $val) = split /=/, $_, 2;

            $key => $val // 'true'
        } split /,/, $attr
    };
};

my $setDiskAttr = sub($self, $type, $disk = {}) {
    my $attrstr = '';

    for my $attr (keys %{$self->diskattr->{$type}}) {
        $attrstr .= !$disk->{$attr}                   ? ''
                  # boolean attr handling
                  : $self->diskattr->{$type}->{$attr} ? ($self->utils->boolIsTrue($disk->{$attr}) ? ",$attr" : '')
                  # non-boolean attr handling
                  :                                     ",$attr=$disk->{$attr}";
    }

    return $attrstr;
};

my $getDiskProps = sub($self, $prop) {
    my ($path, $attrstr) = split /,/, $prop, 2;

    my $attr = $self->$getDiskAttr($attrstr);

    # TODO: /dev... needs to be removed here already so zvol properties can be queried
    # this is also done in the transformer as well as the validator
    $path =~ s!^$ZVOLRX!!;

    # file backed disk
    return { path => $path, %$attr } if Mojo::File->new($path)->is_abs;

    my $props = $self->utils->getZfsProp($path, [ qw(volsize volblocksize refreservation) ]);

    # TODO: extract defaults from schema
    return {
        path        => $path,
        size        => $props->{volsize} // '10G',
        blocksize   => $props->{volblocksize} // '8K',
        sparse      => ($props->{refreservation} // '') eq 'none' ? 'true' : 'false',
        %$attr,
    };
};

sub getPostProcess($self, $cfg) {
    my $disk;
    $cfg->{disk} = [];
    # handle disks before the default getPostProcess
    if ($self->utils->isArrRef($cfg->{attr})) {
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
    if ($self->utils->isArrRef($cfg->{attr})) {
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
    if ($self->utils->isArrRef($cfg->{cdrom}) && $self->utils->isArrRef($cfg->{fs})) {
        for (my $i = $#{$cfg->{fs}}; $i >= 0; $i--) {
            splice @{$cfg->{fs}}, $i, 1
                # cdroms are indexed and there might be empty slots
                if grep { $_ && $_ eq $cfg->{fs}->[$i]->{special} } @{$cfg->{cdrom}};
        }
    }

    # remove device for bootdisk
    $cfg->{device} = [ grep { $_->{match} !~ m!^$ZVOLRX?$cfg->{bootdisk}->{path}$! } @{$cfg->{device}} ]
        if ($self->utils->isHashRef($cfg->{bootdisk}) && $self->utils->isArrRef($cfg->{device}));

    # remove device for disk
    if ($self->utils->isArrRef($cfg->{disk}) && $self->utils->isArrRef($cfg->{device})) {
        for (my $i = $#{$cfg->{device}}; $i >= 0; $i--) {
            splice @{$cfg->{device}}, $i, 1
                # disks are indexed and there might be empty slots
                if grep { $self->utils->isHashRef($_) && $cfg->{device}->[$i]->{match} =~ m!^$ZVOLRX?$_->{path}$! } @{$cfg->{disk}};
        }

    }

    # remove fs/device/disk/cdrom if empty
    $self->utils->isArrRef($cfg->{$_}) && !@{$cfg->{$_}} && delete $cfg->{$_} for qw(fs device disk cdrom);

    return $cfg;
}

sub setPreProcess($self, $cfg) {
    # add cdrom lofs mount to zone config
    if ($self->utils->isArrRef($cfg->{cdrom})) {
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

    # handle bootdisk
    if ($cfg->{bootdisk}) {
        my $disksize = $cfg->{bootdisk}->{size};
        my $diskattr = $self->$setDiskAttr('bootdisk', $cfg->{bootdisk});

        $cfg->{bootdisk} = $cfg->{bootdisk}->{path};
        $cfg->{bootdisk} =~ s!^$ZVOLRX!!;

        # add device if disk is zvol backed
        push @{$cfg->{device}}, { match => "$ZVOLDEV/$cfg->{bootdisk}" }
            if !Mojo::File->new($cfg->{bootdisk})->is_abs;

        $cfg->{bootdisk} .= $diskattr;
    }

    # handle disks
    if ($self->utils->isArrRef($cfg->{disk})) {
        for (my $i = 0; $i < @{$cfg->{disk}}; $i++) {
            next if !$cfg->{disk}->[$i] || ($self->utils->isHashRef($cfg->{disk}->[$i]) && !%{$cfg->{disk}->[$i]});

            my $disk = $cfg->{disk}->[$i]->{path};
            $disk =~ s!^$ZVOLRX!!;

            push @{$cfg->{attr}}, {
                name    => "disk$i",
                type    => 'string',
                value   => $disk . $self->$setDiskAttr('disk', $cfg->{disk}->[$i]),
            };

            # add device if disk is zvol backed
            push @{$cfg->{device}}, { match => "$ZVOLDEV/$disk" }
                if !Mojo::File->new($disk)->is_abs;
        }

        delete $cfg->{disk};
    }

    return $self->SUPER::setPreProcess($cfg);
}

sub install($self, @args) {
    # just install the zone if no image was provided for the bootdisk
    return $self->SUPER::install if !$self->hasimg;

    $self->config->{bootdisk} || do {
        $self->log->warn('WARNING: no bootdisk attribute specified. Not installing image');
        return $self->SUPER::install;
    };

    # cannot zfs recv if snapshots are present
    my $snapshots = $self->utils->snapshot('list', $self->rootds);
    Mojo::Exception->throw("ERROR: destination has snapshots (eg. $snapshots->[0])\n"
        . "must destroy them to overwrite it\n") if @$snapshots;

    my $img = $self->image->image;
    # just install the zone if no valid image was provided for the bootdisk
    return $self->SUPER::install if !%$img;

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
        print "Going to overwrite the boot disk '" . $self->rootds
            . "'\nwith the provided image. Do you want to continue [Y/n]? ";
        chomp ($check = <STDIN>);
    }

    if ($check !~ /^no?$/i) {
        $self->zones->images->seedZvol($img->{_file}, $self->rootds);
        # TODO: '-x volsize' for zfs recv seems not to work so we must reset the
        # volsize to the original value after receive
        privSet({ add => 1, inherit => 1 }, PRIV_SYS_MOUNT);
        $self->utils->exec('zfs', [ 'set', 'volsize=' . $self->config->{bootdisk}->{size},
            $self->rootds ]);
        privSet({ remove => 1, inherit => 1 }, PRIV_SYS_MOUNT);

        $self->SUPER::install;
    }
}

sub poweroff($self) {
    $self->$queryMonitor("quit\n", 1);

    # make sure parent class does 'halt'
    $self->SUPER::poweroff;
}

sub reset($self) {
    $self->$queryMonitor("system_reset\n", 1);
}

sub nmi($self) {
    $self->$queryMonitor("nmi 0\n", 1);
}

sub vnc($self, $listen = '5900') {
    return $self->webvnc($listen) if $self->opts->{web};

    Mojo::Exception->throw("ERROR: permission denied accessing zone root.\n")
        if !-x Mojo::File->new($self->config->{zonepath}, 'root');

    # Zadm::VNC::Proxy is expensive to load and only used for VNC proxying.
    # To avoid having the penalty of loading it even when it is
    # not used we dynamically load it on demand
    $self->utils->loadMod('Zadm::VNC::Proxy');

    my ($ip, $port) = $self->$getIPPort($listen);

    Zadm::VNC::Proxy->new(
        log   => $self->log,
        sock  => $self->vncsocket,
        addr  => $ip,
        port  => $port,
    )->start;
}

sub webvnc($self, $listen = '8000') {
    Mojo::Exception->throw("ERROR: permission denied accessing zone root.\n")
        if !-x Mojo::File->new($self->config->{zonepath}, 'root');

    # Zadm::VNC::NoVNC is expensive to load and only used for web VNC support.
    # To avoid having the penalty of loading it even when it is
    # not used we dynamically load it on demand
    $self->utils->loadMod('Zadm::VNC::NoVNC');

    my ($ip, $port) = $self->$getIPPort($listen);

    Zadm::VNC::NoVNC->new(
        log   => $self->log,
        sock  => $self->vncsocket,
        novnc => $self->utils->gconf->{VNC}->{novnc_path},
        port  => $port,
    )->start(qw(daemon -m production -l), "http://$ip:$port");
}

sub monitor($self) {
    $self->utils->exec('nc', [ '-U', $self->monsocket ],
        'cannot access monitor socket ' . $self->monsocket);
}

sub zStats($self, $raw = 0) {
    return {
        %{$self->SUPER::zStats},
        RAM  => $self->config->{ram} // '-',
        CPUS => $cpuCount->($self->config->{vcpus}, $raw)
            // $self->config->{'capped-cpu'}->{ncpus} // '1',
    };
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid|image_path_or_uri>] [-t <template_path>] <zone_name>
    delete <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-i <image_uuid|image_path_or_uri>] [-f] <zone_name>
    uninstall <zone_name>
    show [zone_name [property[,property]...]]
    list [-H] [-F <format>] [zone_name]
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    pull <image_uuid>
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    console [extra_args] <zone_name>
    monitor <zone_name>
    vnc [-w] [<[bind_addr:]port>] <zone_name>
    webvnc [<[bind_addr:]port>] <zone_name>
    log <zone_name>
    snapshot [-d] <zone_name> [<snapname>]
    rollback [-r] <zone_name> <snapname>
    help [-b <brand>]
    doc [-b <brand>] [-a <attribute>]
    man
    version

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

2020-04-12 had Initial Version

=cut
