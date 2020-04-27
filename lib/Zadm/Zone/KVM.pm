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

has socket    => sub { shift->config->{zonepath} . '/root/tmp/vm.monitor' };
has vncsocket => sub { shift->config->{zonepath} . '/root/tmp/vm.vnc' };
has public    => sub { [ qw(reset nmi vnc) ] };

my $queryMonitor = sub {
    my $self  = shift;
    my $query = shift;

    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $self->socket,
    ) or Mojo::Exception->throw("Cannot open socket $!\n");

    $socket->send($query);

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

sub getPostProcess {
    my $self = shift;
    my $cfg  = shift;

    my $disk;
    $cfg->{disk} = [];
    # handle disks before the default getPostProcess
    if ($cfg->{attr} && ref $cfg->{attr} eq 'ARRAY') {
        for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
            my ($index) = $cfg->{attr}->[$i]->{name} =~ /^disk(\d+)?$/
                or next;

            if (defined $index) {
                $cfg->{disk}->[$index] = $cfg->{attr}->[$i]->{value};
            }
            else {
                $disk = $cfg->{attr}->[$i]->{value};
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

    $cfg = $self->SUPER::getPostProcess($cfg);

    # remove cdrom lofs mount from config
    $cfg->{fs} = [ grep { $_->{special} ne $cfg->{cdrom} } @{$cfg->{fs}} ]
        if ($cfg->{cdrom} && $cfg->{fs} && ref $cfg->{fs} eq 'ARRAY');

    # remove device for bootdisk
    $cfg->{device} = [ grep { $_->{match} !~ m!^(?:$ZVOLRX)?$cfg->{bootdisk}$! } @{$cfg->{device}} ]
        if ($cfg->{bootdisk} && $cfg->{device} && ref $cfg->{device} eq 'ARRAY');

    # remove device for disk
    if ($cfg->{disk} && ref $cfg->{disk} eq 'ARRAY' && $cfg->{device} && ref $cfg->{device} eq 'ARRAY') {
        for (my $i = $#{$cfg->{device}}; $i >= 0; $i--) {
            splice @{$cfg->{device}}, $i, 1
                # disks are indexed and there might be empty slots
                if grep { $_ && $cfg->{device}->[$i]->{match} =~ m!^(?:$ZVOLRX)?$_$! } @{$cfg->{disk}};
        }

    }

    # remove fs/device/disk if empty
    $cfg->{$_} && ref $cfg->{$_} eq 'ARRAY' && !@{$cfg->{$_}} && delete $cfg->{$_} for qw(fs device disk);

    return $cfg;
}

sub setPreProcess {
    my $self = shift;
    my $cfg  = shift;

    # add cdrom lofs mount to zone config
    push @{$cfg->{fs}}, {
        dir     => $cfg->{cdrom},
        options => [ qw(ro nodevices) ],
        special => $cfg->{cdrom},
        type    => 'lofs',
    } if $cfg->{cdrom};

    # add device for bootdisk
    if ($cfg->{bootdisk}) {
        $cfg->{bootdisk} =~ s!^$ZVOLRX!!;
        push @{$cfg->{device}}, { match => "$ZVOLDEV/$cfg->{bootdisk}" };
    }

    # handle disks
    if ($cfg->{disk} && ref $cfg->{disk} eq 'ARRAY') {
        for (my $i = 0; $i < @{$cfg->{disk}}; $i++) {
            next if !$cfg->{disk}->[$i];

            push @{$cfg->{attr}}, {
                name    => "disk$i",
                type    => 'string',
                value   => $cfg->{disk}->[$i],
            };

            $cfg->{disk}->[$i] =~ s!^$ZVOLRX!!;
            push @{$cfg->{device}}, { match => "$ZVOLDEV/$cfg->{disk}->[$i]" };
        }

        delete $cfg->{disk};
    }

    return $self->SUPER::setPreProcess($cfg);
}

sub poweroff {
    my $self = shift;

    $self->$queryMonitor("quit\n");

    # make sure parent class does 'halt'
    $self->SUPER::poweroff;
}

sub reset {
    shift->$queryMonitor("system_reset\n");
}

sub nmi {
    shift->$queryMonitor("nmi 0\n");
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

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid>] [-t <template_path>] <zone_name>
    delete [--purge=vnic] <zone_name>
    edit <zone_name>
    list [zone_name]
    status
    list-images [-b <brand>]
    start <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    console <zone_name>
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
