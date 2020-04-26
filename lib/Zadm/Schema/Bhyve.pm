package Zadm::Schema::Bhyve;
use Mojo::Base 'Zadm::Schema::KVM';

use File::Basename qw(basename);

my $FWPATH = '/usr/share/bhyve/firmware/';

my $SCHEMA;
has schema => sub {
    my $self = shift;

    my $dp = Data::Processor->new($self->SUPER::schema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

$SCHEMA = sub {
    my $self = shift;

    return {
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
        description => 'ACPI',
        default     => 'on',
        example     => '"acpi" : "on"',
        validator   => $self->sv->elemOf(qw(on off)),
        'x-attr'    => 1,
    },
    bootrom     => {
        description => 'boot ROM',
        default     => 'BHYVE',
        example     => '"bootrom" : "BHYVE_DEBUG"',
        validator   => $self->sv->elemOf(map { basename($_, '.fd') } glob "$FWPATH/*.fd"),
        'x-attr'    => 1,
    },
    hostbridge  => {
        description => 'hostbridge',
        default     => 'i440fx',
        example     => '"hostbridge" : "i440fx"',
        validator   => $self->sv->elemOf(qw(i440fx q35 amd netapp none)),
        'x-attr'    => 1,
    },
    xhci        => {
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
