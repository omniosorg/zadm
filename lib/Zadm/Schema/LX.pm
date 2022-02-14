package Zadm::Schema::LX;
use Mojo::Base 'Zadm::Schema::base', -signatures;

my $SCHEMA;
has schema => sub($self) {
    my $dp = Data::Processor->new($self->SUPER::schema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

$SCHEMA = sub($self) {
    return {
    hostid      => {
        optional    => 1,
        validator   => $self->sv->regexp(qr/^$/, 'lx zones do not support hostid emulation'),
    },
    net => {
        optional    => 1,
        array       => 1,
        description => 'network interface',
        members     => {
            ips         => {
                optional    => 1,
                array       => 1,
                description => 'IPs for LX zones',
                validator   => $self->sv->lxIP,
                'x-netprop' => 1,
            },
            gateway     => {
                optional    => 1,
                description => 'Gateway for LX zones',
                validator   => $self->sv->ip,
                'x-netprop' => 1,
            },
            primary     => {
                optional    => 1,
                description => 'Primary Interface for LX zones',
                validator   => $self->sv->bool,
                'x-netprop' => 1,
            },
        },
    },
    'kernel-version' => {
        description  => 'Kernel version',
        # we define a default kernel-version here so the config checker is happy
        # the kernel-version will be set according to the kernel-version in the image metadata
        default      => '4.4',
        validator    => $self->sv->regexp(qr/^[\d.]+$/, 'expected a valid kernel version'),
        'x-attr'     => 1,
    },
    'ipv6' => {
        optional     => 1,
        description  => 'enable/disable IPv6 within LX zone',
        validator    => $self->sv->elemOf(qw(true false)),
        'x-attr'     => 1,
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
