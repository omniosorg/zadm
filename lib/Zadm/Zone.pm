package Zadm::Zone;
use Mojo::Base -base, -signatures;

use Mojo::Exception;
use Mojo::Log;
use Zadm::Zones;

# attributes
has log     => sub { Mojo::Log->new(level => 'debug') };
has zones   => sub($self) { Zadm::Zones->new(log => $self->log) };
has name    => sub { Mojo::Exception->throw("ERROR: zone name must be specified on instantiation.\n") };
has brand   => sub($self) {
    my $name = $self->name;

    Mojo::Exception->throw("ERROR: zone '$name' does not exist.\n")
        if !$self->zones->exists($name);

    $self->zones->list->{$name}->{brand};
};

# private methods
my $loadModule = sub($self, @args) {
    my $brand = $self->brand;

    if (!$self->zones->brandExists($brand)) {
        Mojo::Exception->throw("ERROR: brand '$brand' is not available.\n")
            if !$self->zones->brandAvail($brand);

        $self->zones->installBrand($brand);

        # create a new instance of Zadm::Zones as the list of installed brands has changed
        $self->zones(Zadm::Zones->new(log => $self->log));
    }

    my $module = $self->zones->modmap->{$brand};

    return do {
        $self->zones->utils->loadMod($module);
        $module->new(@args, brand => $brand);
    };
};

sub new($class, @args) {
    return $class->SUPER::new(@args)->$loadModule(@args);
}

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
