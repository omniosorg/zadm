package Zadm::Zones;
use Mojo::Base -base, -signatures;

use Mojo::File;
use Mojo::Home;
use Mojo::Log;
use Mojo::Exception;
use Mojo::Loader qw(load_class);
use Mojo::Promise;
use Mojo::IOLoop::Subprocess;
use List::Util qw(min);
use Term::ANSIColor qw(colored);
use Zadm::Utils;
use Zadm::Zone;

# constants
my @ZONEATTR = qw(zoneid zonename state zonepath uuid brand ip-type debugid);

my $DATADIR  = Mojo::Home->new->detect(__PACKAGE__)->rel_file('var')->to_string; # DATADIR

my $MODPREFIX = 'Zadm::Zone';
my $PKGPREFIX = 'system/zones/brand';

# private static methods
my $statecol = sub($state) {
    for ($state) {
        /^running$/                   && return colored($state, 'green');
        /^(?:configured|incomplete)$/ && return colored($state, 'red');
    }

    return colored($state, 'ansi208');
};

my $mempercol = sub($val) {
    my $str   = sprintf '%.2f%%', $val;
    my $space = ' ' x (9 - length ($str));

    return $space . (
          $val >= 90 ? colored($str, 'red')
        : $val >= 70 ? colored($str, 'ansi208')
        :              $str
    );
};

# private methods
my $list = sub($self) {
    # ignore GZ
    my $zones = $self->utils->readProc('zoneadm', [ qw(list -cpn) ]);

    my %zoneList;
    for my $zone (@$zones) {
        my @zoneattr = split /:/, $zone, scalar @ZONEATTR;
        my $zoneCfg  = { map { $_ => $zoneattr[$self->zonemap->{$_}] } @ZONEATTR };

        $zoneList{$zoneCfg->{zonename}} = $zoneCfg;
    }

    return \%zoneList;
};

# attributes
has log     => sub { Mojo::Log->new(level => $ENV{__ZADMDEBUG} ? 'debug' : 'warn') };
has utils   => sub($self) { Zadm::Utils->new(log => $self->log) };
has images  => sub($self) {
    # Zadm::Images uses some modules which are expensive to load.
    # However, Zadm::Images is only used for a few operations.
    # To avoid having the penalty of loading it even when it is
    # not used we dynamically load it on demand
    Mojo::Exception->throw("ERROR: failed to load 'Zadm::Images'.\n")
        if load_class 'Zadm::Images';

    return Zadm::Images->new(log => $self->log, datadir => $self->datadir)
};
has datadir => $DATADIR;
has brands  => sub {
    return [
        map {
            Mojo::File->new($_)->slurp =~ /<brand\s+name="([^"]+)"/
        } glob '/usr/lib/brand/*/config.xml'
    ];
};
has availbrands => sub($self) {
    my $pkg = $self->utils->readProc('pkg', [ qw(list -aHv), "$PKGPREFIX/*" ]);
    # TODO: the state of sn1/s10 brands is currently unknown
    # while zadm can still be used to configure them we don't advertise them as available
    return [ grep { !/^(?:sn1|s10)$/ } map { m!\Q$PKGPREFIX\E/([^@/]+)\@! } @$pkg ];
};
has brandmap    => sub($self) { $self->utils->genmap($self->brands) };
has avbrandmap  => sub($self) { $self->utils->genmap($self->availbrands) };
has list        => sub($self) { $self->$list };

has zoneName => sub($self) {
    return $self->utils->readProc('zonename')->[0];
};

has isGZ => sub($self) { $self->zoneName eq 'global' };

has modmap => sub($self) {
    # base is the default module
    my %modmap = map { $_ => "${MODPREFIX}::base" } @{$self->brands};

    for my $mod (@{$self->utils->getMods($MODPREFIX)}) {
        my ($name) = $mod =~ /([^:]+)$/;
        $name = lc $name;
        $modmap{$name} &&= $mod;
    }

    return \%modmap;
};

has zonemap => sub {
    my $i = 0;
    return { map { $_ => $i++ } @ZONEATTR };
};

# public methods
sub exists($self, $zName = '') {
    return exists $self->list->{$zName};
}

sub brandExists($self, $brand = '') {
    return exists $self->brandmap->{$brand}
}

sub brandAvail($self, $brand = '') {
    return exists $self->avbrandmap->{$brand}
}

sub installBrand($self, $brand) {
    if ($self->utils->isaTTY) {
        print "Brand '$brand' is not installed. Do you want to install it [Y/n]? ";
        chomp (my $check = <STDIN>);

        # if brand is not installed and the user does not want zadm to install it, exit
        exit 1 if $check =~ /^no?$/i;
    }

    $self->utils->exec('pkg', [ 'install', "$PKGPREFIX/$brand" ]);
}

sub refresh($self) {
    $self->list($self->$list);
}

sub dump($self) {
    my $format = "%-18s%-11s%-9s%6s%8s%8s\n";
    my @header = qw(NAME STATUS BRAND);
    my @zStats = qw(RAM CPUS SHARES);

    printf $format, @header, @zStats;

    my $list  = {
        %{$self->list},
        global  => {
            state   => 'running',
            brand   => 'ipkg',
        },
    };

    # we want the running ones on top and it happens we can just reverse-sort the state
    # also using the original list which does not contain global so we can put it on top
    my @zones = (
        'global',
        sort { $list->{$b}->{state} cmp $list->{$a}->{state} || $a cmp $b } keys %{$self->list}
    );

    my $zStats;
    Mojo::Promise->map(
        { concurrency => $self->utils->ncpus },
        sub($name) {
            Mojo::IOLoop::Subprocess->new->run_p(sub {
                $name ne 'global' ? $self->zone($name)->zStats : {
                    RAM    => $self->utils->getPhysMem,
                    CPUS   => $self->utils->ncpus,
                    SHARES => $self->utils->shares,
                }
            });
        },
        @zones
    )->then(sub(@stats) {
        for my $i (0 .. $#zones) {
            printf $format, $zones[$i],
                # TODO: printf string length breaks with coloured strings
                $statecol->($list->{$zones[$i]}->{state})
                    . (' ' x (11 - length (substr ($list->{$zones[$i]}->{state}, 0, 10)))),
                $list->{$zones[$i]}->{brand},
                map { $stats[$i]->[0]->{$_} } @zStats,
        }
    })->wait;
}

sub memstat($self) {
    my $format = "%-18s%9s%9s%9s%9s%9s%9s\n";
    my @header = qw(NAME RSS RSSCAP RSS% SWAP SWAPCAP SWAP%);

    printf $format, @header;

    my $mcap = $self->utils->kstat->{memory_cap};

    for my $stat (sort { $a <=> $b } keys %$mcap) {
        my ($zone) = keys %{$mcap->{$stat}};

        # reference for convenient access
        my $zmcap = $mcap->{$stat}->{$zone};

        # cap cannot exceed the available amount
        my $physcap = min($zmcap->{physcap}, $self->utils->ram);
        my $swapcap = min($zmcap->{swapcap}, $self->utils->swap);

        printf $format, $zone,
            $self->utils->prettySize($zmcap->{rss}, '%.2f%s'),
            $self->utils->prettySize($physcap, '%.2f%s'),
            $mempercol->($zmcap->{rss} / $physcap * 100),
            $self->utils->prettySize($zmcap->{swap}, '%.2f%s'),
            $self->utils->prettySize($swapcap, '%.2f%s'),
            $mempercol->($zmcap->{swap} / $swapcap * 100);
    }
}

sub dumpBrands($self) {
    my $format = "%-9s%s\n";
    my @header = qw(BRAND STATUS);

    printf $format, @header;
    printf $format, $_, $self->brandExists($_) ? colored('installed', 'green') : colored('available', 'ansi208')
        for sort @{$self->availbrands};
}

sub zone($self, $zName, %opts) {
    my $create = delete $opts{create};

    Mojo::Exception->throw("ERROR: zone '$zName' already exists. use 'edit' to change properties\n")
        if $create && $self->exists($zName);

    Mojo::Exception->throw("ERROR: zone '$zName' does not exist. use 'create' to create a zone\n")
        if !$create && !$self->exists($zName);

    return Zadm::Zone->new(
        zones => $self,
        log   => $self->log,
        utils => $self->utils,
        name  => $zName,
        %opts,
    );
}

sub config($self, $zName) {
    # if we want the config for a particular zone, go ahead
    return $self->zone($zName)->config if $zName;

    return {} if !%{$self->list};

    my $config;
    Mojo::Promise->map(
        { concurrency => $self->utils->ncpus },
        sub($name) {
            Mojo::IOLoop::Subprocess->new->run_p(sub { return $self->zone($name)->config })
        },
        keys %{$self->list}
    )->then(sub(@cfgs) {
        $config = { map { $_->[0]->{zonename} => $_->[0] } @cfgs }
    })->wait;

    return $config;
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
