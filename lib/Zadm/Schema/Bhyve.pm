package Zadm::Schema::Bhyve;
use Mojo::Base 'Zadm::Schema::KVM', -signatures;

use File::Basename qw(basename);

my $FWPATH = '/usr/share/bhyve/firmware/';

my $SCHEMA;
has schema => sub($self) {
    my $dp = Data::Processor->new($self->SUPER::schema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

$SCHEMA = sub($self) {
    return {
    bootdisk    => {
        optional    => 1,
        description => 'boot disk',
        members     => {
            nocache     => {
                optional    => 1,
                description => 'enable/disable caching',
                example     => '"nocache" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            nodelete    => {
                optional    => 1,
                description => 'enable/disable TRIM',
                example     => '"nodelete" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            ro          => {
                optional    => 1,
                description => 'set disk read-only',
                example     => '"ro" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            sync        => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"sync" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            direct      => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"direct" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
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
        description => 'disks',
        members     => {
            nocache     => {
                optional    => 1,
                description => 'enable/disable caching',
                example     => '"nocache" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            nodelete    => {
                optional    => 1,
                description => 'enable/disable TRIM',
                example     => '"nodelete" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            ro          => {
                optional    => 1,
                description => 'set disk read-only',
                example     => '"ro" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            sync        => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"sync" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
                'x-dskattr' => 1,
            },
            direct      => {
                optional    => 1,
                description => 'enable/disable syncing',
                example     => '"direct" : "true"',
                validator   => $self->sv->elemOf(qw(true false)),
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
            feature_mask => {
                optional    => 1,
                description => 'bhyve viona feature mask',
                validator   => $self->sv->regexp(qr/^(?:0x[[:xdigit:]]|\d+)$/, 'expected a numeric value'),
                'x-netprop' => 1,
            },
        },
    },
    acpi        => {
        optional    => 1,
        description => 'ACPI',
        default     => 'on',
        example     => '"acpi" : "on"',
        validator   => $self->sv->elemOf(qw(on off)),
        'x-attr'    => 1,
    },
    bootrom     => {
        optional    => 1,
        description => 'boot ROM',
        default     => 'BHYVE',
        example     => '"bootrom" : "BHYVE_DEBUG"',
        validator   => $self->sv->elemOf(map { basename($_, '.fd') } glob "$FWPATH/*.fd"),
        'x-attr'    => 1,
    },
    hostbridge  => {
        optional    => 1,
        description => 'hostbridge',
        default     => 'i440fx',
        example     => '"hostbridge" : "i440fx"',
        validator   => $self->sv->elemOf(qw(i440fx q35 amd netapp none)),
        'x-attr'    => 1,
    },
    xhci        => {
        optional    => 1,
        description => 'XHCI',
        default     => 'on',
        example     => '"xhci" : "off"',
        validator   => $self->sv->elemOf(qw(on off)),
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
