package Zadm::Zones;
use Mojo::Base -base;

use Mojo::File;
use Mojo::Log;
use Mojo::Exception;
use Mojo::Promise;
use Mojo::IOLoop::Subprocess;
use FindBin;
use File::Spec;
use List::Util qw(min);
use Term::ANSIColor qw(colored);
use Zadm::Utils;
use Zadm::Image;
use Zadm::Zone;

# constants
my @ZONEATTR = qw(zoneid zonename state zonepath uuid brand ip-type debugid);

my $DATADIR = "$FindBin::RealBin/../var"; # DATADIR

my $MODPREFIX = 'Zadm::Zone';
my $PKGPREFIX = 'system/zones/brand';

# private static methods
my $statecol = sub {
    my $state = shift;

    for ($state) {
        /^running$/                   && return colored($state, 'green');
        /^(?:configured|incomplete)$/ && return colored($state, 'red');
    }

    return colored($state, 'ansi208');
};

my $mempercol = sub {
    my $val = shift;

    my $str   = sprintf '%.2f%%', $val;
    my $space = ' ' x (9 - length ($str));

    return $space . (
          $val >= 90 ? colored($str, 'red')
        : $val >= 70 ? colored($str, 'ansi208')
        : $str
    );
};

# private methods
my $list = sub {
    my $self = shift;

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
has availbrands => sub {
    my $pkg = shift->utils->readProc('pkg', [ qw(list -aHv), "$PKGPREFIX/*" ]);
    # TODO: the state of sn1/s10 brands is currently unknown
    # while zadm can still be used to configure them we don't advertise them as available
    return [ grep { !/^(?:sn1|s10)$/ } map { m!\Q$PKGPREFIX\E/([^@/]+)\@! } @$pkg ];
};
has brandmap    => sub { my $self = shift; $self->utils->genmap($self->brands) };
has avbrandmap  => sub { my $self = shift; $self->utils->genmap($self->availbrands) };
has list        => sub { shift->$list };

has zoneName => sub {
    return shift->utils->readProc('zonename')->[0];
};

has isGZ => sub { shift->zoneName eq 'global' };

has modmap => sub {
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

has zonemap => sub {
    my $i = 0;
    return { map { $_ => $i++ } @ZONEATTR };
};

# public methods
sub exists {
    return exists shift->list->{shift // ''};
}

sub brandExists {
    return exists shift->brandmap->{shift // ''}
}

sub brandAvail {
    return exists shift->avbrandmap->{shift // ''}
}

sub installBrand {
    my $self  = shift;
    my $brand = shift;

    my $check;
    if (!$self->utils->isaTTY || $ENV{__ZADMTEST}) {
        $check = 'yes';
    }
    else {
        print "Brand '$brand' is not installed. Do you want to install it [Y/n]? ";
        chomp ($check = <STDIN>);
    }

    # if brand is not installed and the user does not want zadm to install it, exit
    exit 1 if $check =~ /^no?$/i;

    $self->utils->exec('pkg', [ 'install', "$PKGPREFIX/$brand" ]);
}

sub refresh {
    my $self = shift;

    $self->list($self->$list);
}

sub dump {
    my $self = shift;

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
    Mojo::Promise->all(
        # global zone stats
        Mojo::IOLoop::Subprocess->new->run_p(sub {
            return {
                RAM     => $self->utils->getPhysMem,
                CPUS    => $self->utils->readProc('getconf', [ qw(NPROCESSORS_ONLN) ])->[0] || '-',
                SHARES  => (($self->utils->readProc('zonecfg', [ qw(-z global info cpu-shares) ])->[0] // '')
                    =~ /cpu-shares:\s+(\d+)/)[0] // '1',
            }
        }),
        # non-global zone stats
        map {
            my $name = $_;
            Mojo::IOLoop::Subprocess->new->run_p(sub { return $self->zone($name)->zStats })
        } @zones[1 .. $#zones]
    )->then(sub { $zStats = { map { $zones[$_] => $_[$_]->[0] } (0 .. $#zones) } }
    )->wait;

    for my $zone (@zones) {
        printf $format, $zone,
            # TODO: printf string length breaks with coloured strings
            $statecol->($list->{$zone}->{state})
                . (' ' x (11 - length (substr ($list->{$zone}->{state}, 0, 10)))),
            $list->{$zone}->{brand},
            map { $zStats->{$zone}->{$_} } @zStats,
    }
}

sub memstat {
    my $self = shift;

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

sub dumpBrands {
    my $self = shift;

    my $format = "%-9s%s\n";
    my @header = qw(BRAND STATUS);

    printf $format, @header;
    printf $format, $_, $self->brandExists($_) ? colored('installed', 'green') : colored('available', 'ansi208')
        for sort @{$self->availbrands};
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

sub config {
    my $self  = shift;
    my $zName = shift;

    # if we want the config for a particular zone, go ahead
    return $self->zone($zName)->config if $zName;

    my @zones = keys %{$self->list}
        or return {};

    my $config;
    Mojo::Promise->all(
        map {
            my $name = $_;
            Mojo::IOLoop::Subprocess->new->run_p(sub { return $self->zone($name)->config })
        } @zones
    )->then(sub { $config->{$_->[0]->{zonename}} = $_->[0] for @_ }
    )->wait;

    return $config;
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
