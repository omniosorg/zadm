package Zadm::Zones;
use Mojo::Base -base;

use Mojo::Home;
use Mojo::File;
use Mojo::Log;
use Mojo::Exception;
use File::Spec;
use Zadm::Utils;
use Zadm::Image;
use Zadm::Zone;

# constants
my %ZMAP = (
    zoneid    => 0,
    zonename  => 1,
    state     => 2,
    zonepath  => 3,
    uuid      => 4,
    brand     => 5,
    'ip-type' => 6,
    debugid   => 7,
);

my $DATADIR = Mojo::Home->new->rel_file('../var')->to_string; # DATADIR

my $MODPREFIX = 'Zadm::Zone';

# attributes
has loglvl  => 'warn'; # override to 'debug' for development
has log     => sub { Mojo::Log->new(level => shift->loglvl) };
has utils   => sub { Zadm::Utils->new(log => shift->log) };
has image   => sub { my $self = shift; Zadm::Image->new(log => $self->log, datadir => $self->datadir) };
has datadir => $DATADIR;
has brands  => sub {
    return [
        map {
            Mojo::File->new($_)->slurp =~ /<brand\s+name="([^"]+)"/
        } glob '/usr/lib/brand/*/config.xml'
    ];
};
has brandmap => sub { my $self = shift; $self->utils->genmap($self->brands) };

has brandFilter => '';

has zoneName => sub {
    my $self = shift;
    
    my $zonename = $self->utils->pipe('zonename');
    chomp (my $zone = <$zonename>);

    return $zone;
};

has isGZ => sub { shift->zoneName eq 'global' };

has modmap  => sub {
    my $self = shift;

    # base is the default module
    my %modmap = map { $_ => $MODPREFIX . '::base' } @{$self->brands};

    for my $path (@INC) {
        my @mDirs = split /::|\//, $MODPREFIX;
        my $fPath = File::Spec->catdir($path, @mDirs, '*.pm');
        for my $file (sort glob($fPath)) {
            my ($volume, $modulePath, $modName) = File::Spec->splitpath($file);
            $modName =~ s/\.pm$//;
            next if $modName eq 'base';

            $modmap{lc $modName} = $MODPREFIX . "::$modName" if exists $modmap{lc $modName};
        }
    }

    return \%modmap;
};

# public methods
sub list {
    my $self = shift;

    my $zones = $self->utils->pipe('zoneadm', [ qw(list -cp) ]);

    my %zoneList;
    while (my $zone = <$zones>) {
        chomp $zone;
        my $zoneCfg = { map { $_ => (split /:/, $zone)[$ZMAP{$_}] } keys %ZMAP };
        # ignore GZ
        next if $zoneCfg->{zonename} eq 'global';
        # apply brand filter
        next if $self->brandFilter && $zoneCfg->{brand} !~ /$self->brandFilter/;

        $zoneList{$zoneCfg->{zonename}} = $zoneCfg;
    }

    return \%zoneList;
}

sub count {
    return keys %{shift->list};
}

sub exists {
    my $self  = shift;
    my $zName = shift // '';

    return exists $self->list->{$zName};
}

sub brandExists {
    my $self  = shift;
    my $brand = shift // '';

    return exists $self->brandmap->{$brand};
}

sub zone {
    my $self  = shift;
    my $zName = shift;
    my %opts  = @_;

    my $create = delete $opts{create};

    Mojo::Exception->throw("ERROR: zone '$zName' already exists. use 'edit' to change properties\n")
        if $create && $self->exists($zName);

    Mojo::Exception->throw("ERROR: zone '$zName' does not exist. use 'create' to create a zone\n")
        if !$create && !$self->exists($zName);

    return Zadm::Zone->new(
        zones => $self,
        log   => $self->log,
        utils => $self->utils,
        image => $self->image,
        name  => $zName,
        %opts,
    );
}

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
