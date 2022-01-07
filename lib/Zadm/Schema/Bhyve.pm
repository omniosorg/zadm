package Zadm::Schema::Bhyve;
use Mojo::Base 'Zadm::Schema::KVM', -signatures;

use File::Basename qw(basename);

my $FWPATH = '/usr/share/bhyve/firmware/';

my $SCHEMA;
has schema => sub($self) {
    my $kvmschema = $self->SUPER::schema;
    # we need to drop these parent entries since merging would result in checking parent validators too;
    # the additional options from the bhyve brand would fail the check from the parent
    delete $kvmschema->{$_} for qw(diskif netif);

    my $dp = Data::Processor->new($kvmschema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

$SCHEMA = sub($self) {
    return {
    bootdisk    => {
        optional    => 1,
        description => 'ZFS volume which will be attached as the boot disk',
        members     => {
            nocache     => {
                optional    => 1,
                description => 'enable/disable caching',
                example     => '"nocache" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            nodelete    => {
                optional    => 1,
                description => 'enable/disable TRIM',
                example     => '"nodelete" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            ro          => {
                optional    => 1,
                description => 'set disk read-only',
                example     => '"ro" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            sync        => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"sync" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            direct      => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"direct" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            sectorsize  => {
                optional    => 1,
                description => 'set logical/physical sector size',
                example     => '"sectorsize" : "512/4096"',
                validator   => $self->sv->sectorSize,
                transformer => $self->sv->toBytes,
                'x-dskattr' => 0,
            },
        },
    },
    disk        => {
        optional    => 1,
        array       => 1,
        allow_empty => 1,
        description => 'ZFS volume which will be attached as disk',
        members     => {
            nocache     => {
                optional    => 1,
                description => 'enable/disable caching',
                example     => '"nocache" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            nodelete    => {
                optional    => 1,
                description => 'enable/disable TRIM',
                example     => '"nodelete" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            ro          => {
                optional    => 1,
                description => 'set disk read-only',
                example     => '"ro" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            sync        => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"sync" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            direct      => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"direct" : "true"',
                validator   => $self->sv->bool,
                'x-dskattr' => 1,
            },
            sectorsize  => {
                optional    => 1,
                description => 'set logical/physical sector size',
                example     => '"sectorsize" : "512/4096"',
                validator   => $self->sv->sectorSize,
                transformer => $self->sv->toBytes,
                'x-dskattr' => 0,
            },
        },
    },
    net => {
        optional    => 1,
        array       => 1,
        description => 'network interface',
        members     => {
            netif => {
                optional    => 1,
                description => 'network interface type',
                validator   => $self->sv->elemOf(qw(virtio virtio-net-viona virtio-net e1000)),
                'x-netprop' => 1,
            },
            feature_mask => {
                optional    => 1,
                description => '(viona) set negotiated feature mask',
                validator   => $self->sv->regexp(qr/^(?:0x[[:xdigit:]]+|\d+)$/i, 'expected a numeric value'),
                'x-netprop' => 1,
            },
            vqsize => {
                optional    => 1,
                description => '(viona) set ring size - power of 2 between 4 and 32768 (default: 1024)',
                validator   => $self->sv->elemOf(map { 2 ** $_ } 2..15),
                'x-netprop' => 1,
            },
            mtu => {
                optional    => 1,
                description => '(virtio) set mtu',
                validator   => $self->sv->numRange(60, 65535),
                'x-netprop' => 1,
            },
            backend => {
                optional    => 1,
                description => '(virtio,e1000) select backend network interface',
                validator   => $self->sv->elemOf(qw(dlpi)),
                'x-netprop' => 1,
            },
            promiscrxonly => {
                optional    => 1,
                description => '(virtio,e1000) enable receive-only promiscuous mode',
                validator   => $self->sv->bool,
                'x-netprop' => 1,
            },
            promiscphys => {
                optional    => 1,
                description => '(virtio,e1000) enable physical level promiscuous mode',
                validator   => $self->sv->bool,
                'x-netprop' => 1,
            },
            promiscsap => {
                optional    => 1,
                description => '(virtio,e1000) enable SAP level promiscuous mode',
                validator   => $self->sv->bool,
                'x-netprop' => 1,
            },
            promiscmulti => {
                optional    => 1,
                description => '(virtio,e1000) enable promiscuous mode for multicast',
                validator   => $self->sv->bool,
                'x-netprop' => 1,
            },
        },
    },
    ppt         => {
        optional    => 1,
        array       => 1,
        description => 'PCI devices to pass through',
        members     => {
            device => {
                description => 'PCI device to pass through',
                example     => '"device" : "ppt0"',
                validator   => $self->sv->ppt,
            },
            state  => {
                description => 'PCI device state',
                default     => 'on',
                example     => '"state" : "on"',
                validator   => $self->sv->bool(map { "slot$_" } 0 .. 7),
            },
        },
        transformer => $self->sv->toHash('device', 1),
    },
    virtfs      => {
        optional    => 1,
        array       => 1,
        description => 'Share a filesystem to the guest using Virtio 9p (VirtFS)',
        members     => {
            name   => {
                description => 'VirtFS filesystem name',
                example     => '"name" : "share0"',
                validator   => $self->sv->regexp(qr/^.+$/, 'expected a string'),
            },
            path   => {
                description => 'VirtFS filesystem path',
                example     => '"path" : "/data/share0"',
                validator   => $self->sv->absPath(0),
            },
            ro     => {
                optional    => 1,
                description => 'set share read-only',
                example     => '"ro" : "true"',
                validator   => $self->sv->bool,
            },
        },
    },
    acpi        => {
        optional    => 1,
        description => 'generate ACPI tables for the guest',
        default     => 'on',
        example     => '"acpi" : "on"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },
    bootrom     => {
        optional    => 1,
        description => 'boot ROM to use for starting the virtual machine',
        default     => 'BHYVE',
        example     => '"bootrom" : "BHYVE_DEBUG"',
        validator   => $self->sv->elemOf(grep { !/^BHYVE_VARS$/ } map { basename($_, '.fd') } glob "$FWPATH/*.fd"),
        'x-attr'    => 1,
    },
    'cloud-init' => {
        optional    => 1,
        description => 'provide cloud-init data - on|off|file path|URL',
        default     => 'off',
        example     => '"cloud-init" : "on"',
        validator   => $self->sv->cloudinit,
        'x-attr'    => 1,
    },
    diskif      => {
        optional    => 1,
        description => 'disk type',
        default     => 'virtio',
        example     => '"diskif" : "virtio"',
        validator   => $self->sv->elemOf(qw(virtio virtio-blk nvme ahci ahci-hd ahci-cd ide)),
        'x-attr'    => 1,
    },
    hostbridge  => {
        optional    => 1,
        description => 'type of emulated system host bridge',
        default     => 'i440fx',
        example     => '"hostbridge" : "i440fx"',
        validator   => $self->sv->hostbridge,
        'x-attr'    => 1,
    },
    memreserve  => {
        optional    => 1,
        description => 'pre-allocate and retain memory even when the zone is shut down',
        example     => '"memreserve" : "on"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },
    netif       => {
        optional    => 1,
        description => 'network interface type',
        default     => 'virtio',
        example     => '"netif" : "virtio"',
        validator   => $self->sv->elemOf(qw(virtio virtio-net-viona virtio-net e1000)),
        'x-attr'    => 1,
    },
    password    => {
        optional    => 1,
        description => 'provide cloud-init password/hash or path to file',
        example     => '"password" : "$6$SEeDRaFR$...5/"',
        validator   => $self->sv->stringorfile,
        transformer => $self->sv->toPWHash,
        'x-attr'    => 1,
    },
    rng         => {
        optional    => 1,
        description => 'attach VirtIO random number generator (RNG) to the guest',
        default     => 'off',
        example     => '"rng" : "on"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },
    sshkey      => {
        optional    => 1,
        description => 'provide cloud-init public SSH key - string or path to file',
        example     => '"sshkey" : "/root/.ssh/id_rsa.pub"',
        validator   => $self->sv->stringorfile,
        'x-attr'    => 1,
    },
    vga         => {
        optional    => 1,
        description => 'type of VGA emulation to use',
        example     => '"vga" : "on"',
        validator   => $self->sv->elemOf(qw(on off io)), # change to bool once bhyve supports it
        'x-attr'    => 1,
    },
    xhci        => {
        optional    => 1,
        description => 'emulated USB tablet interface',
        default     => 'on',
        example     => '"xhci" : "off"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },

}};

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

2020-04-12 had Initial Version

=cut
