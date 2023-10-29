package Zadm::Schema::Bhyve;
use Mojo::Base 'Zadm::Schema::KVM', -signatures;

my $SCHEMA;
has schema => sub($self) {
    my $kvmschema = $self->SUPER::schema;
    # we need to drop these parent entries since merging would result in checking parent validators too;
    # the additional options from the bhyve brand would fail the check from the parent
    # also dropping attributes not supported by the bhyve brand (e.g. cpu)
    delete $kvmschema->{$_} for qw(bootorder cpu diskif netif vnc);

    my $dp = Data::Processor->new($kvmschema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

$SCHEMA = sub($self) {
    my $diskmembers = {
        nocache     => {
            optional    => 1,
            description => 'enable/disable caching',
            example     => '"nocache" : "true"',
            validator   => $self->sv->bool,
            'x-dskbool' => 1,
        },
        nodelete    => {
            optional    => 1,
            description => 'enable/disable TRIM',
            example     => '"nodelete" : "true"',
            validator   => $self->sv->bool,
            'x-dskbool' => 1,
        },
        ro          => {
            optional    => 1,
            description => 'set disk read-only',
            example     => '"ro" : "true"',
            validator   => $self->sv->bool,
            'x-dskbool' => 1,
        },
        sync        => {
            optional    => 1,
            description => 'enable/disable syncing',
            example     => '"sync" : "true"',
            validator   => $self->sv->bool,
            'x-dskbool' => 1,
        },
        direct      => {
            optional    => 1,
            description => 'enable/disable syncing',
            example     => '"direct" : "true"',
            validator   => $self->sv->bool,
            'x-dskbool' => 1,
        },
        diskif      => {
            optional    => 1,
            description => 'disk type',
            example     => '"diskif" : "virtio"',
            validator   => $self->sv->elemOf(qw(virtio virtio-blk nvme ahci ahci-hd ahci-cd ide)),
        },
        sectorsize  => {
            optional    => 1,
            description => 'set logical/physical sector size',
            example     => '"sectorsize" : "512/4096"',
            validator   => $self->sv->sectorSize,
            transformer => $self->sv->toBytes,
            'x-dskbool' => 0,
        },
        ser         => {
            optional    => 1,
            description => 'serial number of disk, upper-case alpha-numeric, up to 20 characters',
            example     => '"serial" : "XYZ123"',
            validator   => $self->sv->regexp(qr/^[\dA-Z-]{1,20}$/),
            'x-dskbool' => 0,
        },
        maxq        => {
            optional    => 1,
            description => '(nvme) Max number of queues (default: 16)',
            example     => '"maxq" : "12"',
            validator   => $self->sv->numRange(1, 16),
            'x-dskbool' => 0,
        },
        qsz         => {
            optional    => 1,
            description => '(nvme) Max elements in each queue (default: 2048)',
            example     => '"qsz" : "1024"',
            validator   => $self->sv->numRange(1, 2048),
            'x-dskbool' => 0,
        },
        ioslots     => {
            optional    => 1,
            description => '(nvme) Max number of concurrent I/O requests (default: 8)',
            example     => '"ioslots" : "16"',
            validator   => $self->sv->numRange(1, 128),
            'x-dskbool' => 0,
        },
        sectsz      => {
            optional    => 1,
            description => '(nvme) sector size override (prefer sectorsize)',
            example     => '"sectsz" : "4096"',
            validator   => $self->sv->elemOf(qw(512 4096 8192)),
            'x-dskbool' => 0,
        },
        eui64       => {
            optional    => 1,
            description => '(nvme) IEEE Extended Unique Identifier (8 byte value)',
            example     => '"eui64" : "0x589cfc2045c20001"',
            validator   => $self->sv->regexp(qr/^0x[[:xdigit:]]{1,16}$/i, 'expected a hex value up to 8 bytes'),
            'x-dskbool' => 0,
        },
        dsm         => {
            optional    => 1,
            description => '(nvme) DataSet Management support (default: auto)',
            example     => '"dsm" : "enable"',
            validator   => $self->sv->elemOf(qw(auto enable disable)),
            'x-dskbool' => 0,
        },
    };

    return {
    bootdisk    => {
        optional    => 1,
        description => 'ZFS volume which will be attached as the boot disk',
        members     => $diskmembers,
    },
    bootnext    => {
        optional    => 1,
        description => 'device to be used for the next boot only',
        example     => '"bootnext" : "cdrom0"',
        validator   => $self->sv->bhyveBootDev,
        'x-attr'    => 1,
    },
    bootorder   => {
        optional    => 1,
        array       => 1,
        description => 'boot order',
        example     => '"bootorder" : "path0,bootdisk,cdrom0"',
        validator   => $self->sv->bhyveBootDev,
        transformer => $self->sv->toArray(qr/,/),
        'x-attr'    => 1,
    },
    disk        => {
        optional    => 1,
        array       => 1,
        allow_empty => 1,
        description => 'ZFS volume which will be attached as disk',
        members     => $diskmembers,
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
        validator   => $self->sv->bootrom,
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
    uefivars    => {
        optional    => 1,
        description => 'enable/disable persistent UEFI vars',
        default     => 'on',
        example     => '"uefivars" : "on"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },
    vnc         => {
        optional    => 1,
        description => 'VNC',
        members     => {
            enabled     => {
                description => 'enable/disable VNC',
                default     => 'off',
                example     => '"enabled" : "on"',
                validator   => $self->sv->bool,
                'x-vncbool' => 1,
                'x-vncidx'  => 0,
            },
            wait        => {
                optional    => 1,
                description => 'pause boot until the first VNC connection is established',
                example     => '"wait" : "on"',
                validator   => $self->sv->bool,
                'x-vncbool' => 1,
                'x-vncidx'  => 1,
            },
            unix        => {
                optional    => 1,
                description => 'sets up a VNC server UNIX socket at the specified path (relative to the zone root)',
                example     => '"unix" : "/tmp/vncsock.vnc"',
                validator   => $self->sv->absPath(0),
                'x-vncbool' => 0,
                'x-vncidx'  => 2,
            },
            w           => {
                optional    => 1,
                description => 'horizontal screen resolution',
                example     => '"w" : "1200"',
                validator   => $self->sv->numRange(320, 1920),
                'x-vncbool' => 0,
                'x-vncidx'  => 3,
            },
            h           => {
                optional    => 1,
                description => 'vertical screen resolution',
                example     => '"h" : "800"',
                validator   => $self->sv->numRange(200, 1200),
                'x-vncbool' => 0,
                'x-vncidx'  => 4,
            },
            password    => {
                optional    => 1,
                description => 'password for the VNC server or path to a file containing the password',
                example     => '"password" : "secret"',
                validator   => $self->sv->stringorfile,
                'x-vncbool' => 0,
                'x-vncidx'  => 5,
            },
        },
        transformer => $self->sv->toVNCHash,
        'x-simple'  => 1,
    },
    xhci        => {
        optional    => 1,
        description => 'emulated USB tablet interface',
        default     => 'on',
        example     => '"xhci" : "off"',
        validator   => $self->sv->bool,
        'x-attr'    => 1,
    },
    }
};

1;

__END__

=head1 COPYRIGHT

Copyright 2023 OmniOS Community Edition (OmniOSce) Association.

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
