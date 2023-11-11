package Zadm::Schema::Emu;
use Mojo::Base 'Zadm::Schema::KVM', -signatures;

my $SCHEMA;
has schema => sub($self) {
    my $kvmschema = $self->SUPER::schema;
    # we need to drop these parent entries since merging would result in checking parent validators too;
    # the additional options from the emu brand would fail the check from the parent
    delete $kvmschema->{$_} for qw(cpu);

    my $dp = Data::Processor->new($kvmschema);
    my $ec = $dp->merge_schema($self->$SCHEMA);

    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}));

    return $dp->schema;
};

has archs  => sub {
    return [
        map { /qemu-system-(\w+)$/ } glob '/opt/ooce/qemu/bin/qemu-system-*'
    ];
};

$SCHEMA = sub($self) {
    return {
    arch    => {
        description => 'architecture to emulate',
        example     => '"arch" : "aarch64"',
        validator   => $self->sv->elemOf(@{$self->archs}),
        'x-attr'    => 1,
    },
    cpu     => {
        description => 'cpu to emulate',
        example     => '"cpu" : "cortex-a53"',
        validator   => $self->sv->regexp(qr/^.+$/, 'expected a string'),
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
