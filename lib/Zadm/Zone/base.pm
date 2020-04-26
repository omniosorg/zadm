package Zadm::Zone::base;
use Mojo::Base -base;

use Mojo::File;
use Mojo::Log;
use Data::Processor;
use Pod::Usage;
use Pod::Find qw(pod_where);
use Zadm::Zones;
use Zadm::Utils;
use Zadm::Image;
use Zadm::Validator;

# constants/definitions
has purgemap   => sub { shift->utils->genmap([ qw(vnic zvol) ]) };
has statemap   => sub {
    {
        boot        => [ qw(installed) ],
        shutdown    => [ qw(running) ],
        halt        => [ qw(running) ],
        install     => [ qw(configured) ],
        uninstall   => [ qw(incomplete installed) ],

    }
};
# TODO: properties that can only be set on creation/needs verification
has createprop => sub { [ qw(zonename zonepath brand ip-type) ] };
has template   => sub {
    my $self = shift;
    my $name = $self->name;

    return {
        zonename    => $name,
        zonepath    => ($ENV{__ZADM_ALTROOT} // '') . "/zones/$name",
        brand       => $self->brand,
        'ip-type'   => 'exclusive',
    }
};
has options => sub {
    {
        create  => {
            brand => {
                getopt => 'brand|b=s',
                mand   => 1,
            },
        },
    }
};

# private methods
my $resIsArray = sub {
    my $self = shift;
    my $res  = shift;

    return exists $self->schema->{$res} && $self->schema->{$res}->{array};
};

my $resIsAttr = sub {
    my $self = shift;
    my $res  = shift;

    return exists $self->schema->{$res} && $self->schema->{$res}->{'x-attr'};
};

my $propIsArray = sub {
    my $self = shift;
    my $res  = shift;
    my $prop = shift;

    return exists $self->schema->{$res}->{members}->{$prop}
        && $self->schema->{$res}->{members}->{$prop}->{array};
};

my $propIsHash = sub {
    my $self = shift;
    my $res  = shift;
    my $prop = shift;

    return exists $self->schema->{$res}->{members}->{$prop}->{members};
};

my $getArray = sub {
    my $self = shift;
    my $val  = shift;

    # remove leading and trailing square brackets
    $val =~ s/^\s*\[|\]\s*$//g;

    return [ split /,/, $val ];
};

my $setArray = sub {
    my $self = shift;
    my $val  = shift;

    return join (',', @$val);
};

my $getHash = sub {
    my $self = shift;
    my $val  = shift;

    # remove leading and trailing brackets
    $val =~ s/^\s*\(|\)\s*$//g;

    return { split /[,=]/, $val };
};

my $setHash = sub {
    my $self = shift;
    my $val  = shift;

    return '(' . join (',', map { "$_=$val->{$_}" } keys %$val) . ')';
};

my $getVal = sub {
    my $self = shift;
    my $res  = shift;
    my $prop = shift;
    my $val  = shift;

    return $self->$propIsArray($res, $prop) ? $self->$getArray($val)
         : $self->$propIsHash($res, $prop)  ? $self->$getHash($val)
         : $val;
};

my $setVal = sub {
    my $self = shift;
    my $prop = shift;

    return ref $prop eq 'ARRAY' ? $self->$setArray($prop)
         : ref $prop eq 'HASH'  ? $self->$setHash($prop)
         : $prop;
};

my $isRes = sub {
    my $self = shift;
    my $prop = shift;

    return exists $self->resmap->{$prop};
};

my $isResProp = sub {
    my $self = shift;
    my $res  = shift;
    my $prop = shift;

    return exists $self->schema->{$res}->{members}->{$prop};
};

my $isProp = sub {
    my $self = shift;
    my $prop = shift;

    return exists $self->schema->{$prop};
};

my $resourceExisted = sub {
    my $self = shift;
    my $res  = shift;
    my $prop = shift || '';
    my $val  = shift || '';

    return !$prop || !$val          ? exists $self->oldConf->{$res}
         : $self->$resIsArray($res) ? grep { $_->{$prop} eq $val } @{$self->oldConf->{$res}}
         : $self->oldConf->{$res}->{$prop} eq $val;
};

my $addResource = sub {
    my $self  = shift;
    my $res   = shift;
    my $props = shift;

    my $name = $self->name;
    my @cmd  = ('-z', $name, 'add', $res, ';');

    push @cmd, $self->encodeProp($res, $_, $props->{$_}) for keys %$props;

    push @cmd, qw(end);

    $self->utils->exec('zonecfg', \@cmd, "cannot config zone $name");
};

my $delResource = sub {
    my $self  = shift;
    my $res   = shift;

    my $name = $self->name;
    my @cmd  = ('-z', $name, qw(remove -F), $res);

    $self->utils->exec('zonecfg', \@cmd, "cannot delete resource '$res' from zone '$name'");
};

my $clearResources = sub {
    my $self = shift;

    my $conf = $self->setPreProcess($self->oldConf);

    $self->$delResource($_) for grep { exists $self->resmap->{$_} } keys %$conf;
};

my $setProperty = sub {
    my $self = shift;
    my $prop = shift;

    my $name = $self->name;

    my @cmd = ('-z', $name, 'set', $prop, '=',
        q{"} . $self->$setVal($self->config->{$prop}) . q{"});

    $self->utils->exec('zonecfg', \@cmd, "cannot set property '$prop'");
};

my $clearProperty = sub {
    my $self = shift;
    my $prop = shift;

    my $name = $self->name;

    my @cmd = ('-z', $name, 'clear', $prop);

    $self->utils->exec('zonecfg', \@cmd, "cannot clear property $prop");
};

my $getConfig = sub {
    my $self = shift;

    my $config = {};

    return {} if !$self->zones->exists($self->name);

    my $props = $self->utils->pipe('zonecfg', ['-z', $self->name, 'info']);

    my $res;
    while (my $line = <$props>) {
        chomp ($line);
        # remove square brackets at beginning and end of line
        $line =~ s/^(\s*)\[/$1/ && $line =~ s/\]\s*//;
        # drop lines ending with 'not specified'
        next if $line =~ /not\s+specified$/;
        my ($isres, $prop, $val) = $line =~ /^(\s+)?([^:]+):(?:\s+(.*))?$/;
        # at least property must be valid
        $prop or do {
            $self->log->warn("could not decode '$line'");
            next;
        };
        if ($isres) {
            # decode property
            ($prop, $val) = $self->decodeProp($res, $prop, $val);
            # check if property exists in schema
            $self->$isResProp($res, $prop) or do {
                $self->log->warn("'$prop' is not a member of resource '$res'");
                next;
            };
            if ($self->$resIsArray($res)) {
                $config->{$res}->[-1]->{$prop} = $self->$getVal($res, $prop, $val);
            }
            else {
                $config->{$res}->{$prop} = $self->$getVal($res, $prop, $val);
            }
        }
        else {
            # check if property exists in schema
            $self->$isProp($prop) or do {
                $self->log->warn("$prop does not exist in schema");
                next;
            };
            # check if property is a resource
            $self->$isRes($prop) && do {
                $res = $prop;
                push @{$config->{$prop}}, {}
                    if $self->$resIsArray($prop);

                next;
            };
            $config->{$prop} = $val;
        }
    }
    $config = $self->getPostProcess($config);

    return $config;
};

my $setConfig = sub {
    my $self   = shift;
    my $config = shift;

    # get current config so we can check for changes
    $self->oldConf($self->$getConfig);

    # validate new config
    $self->validate($config) if !$self->valid;

    # we don't support brand changes
    Mojo::Exception->throw("ERROR: brand cannot be changed from '"
        . $self->config->{brand} . "' to '" . $config->{brand} . ".\n")
        if $self->config->{brand} ne $config->{brand};

    # set new config
    $self->config($config);

    $self->exists || $self->create({
        map { $_ => $config->{$_} } @{$self->createprop}
    });

    # clean up all existing resources
    $self->$clearResources;

    $config = $self->setPreProcess($self->config);

    my $installed = !$self->is('configured');
    for my $prop (keys %$config) {
        $self->log->debug("processing property '$prop'");

        # skip props that cannot be changed once the zone is installed
        next if $installed && exists $self->createpropmap->{$prop};

        if (ref $self->config->{$prop} eq 'ARRAY') {
            $self->log->debug("property '$prop' is a resource array");

            $self->$addResource($prop, $_) for (@{$self->config->{$prop}});
        }
        elsif ($self->$isRes($prop)) {
            $self->log->debug("property '$prop' is a resource");

            $self->$addResource($prop, $self->config->{$prop});
        }
        else {
            next if !$self->oldConf->{$prop} && !$self->config->{$prop}
                || $self->oldConf->{$prop} && $self->oldConf->{$prop} eq $self->config->{$prop};

            $self->log->debug("property '$prop' changed: " . ($self->oldConf->{$prop} // '(none)') . ' -> '
                . ($self->config->{$prop} // '(none)'));

            if ($self->config->{$prop}) {
                $self->$setProperty($prop);
            }
            else {
                $self->$clearProperty($prop);
            }
        }
    }

    return $self->valid;
};

my $zoneCmd = sub {
    my $self     = shift;
    my $cmd      = shift;
    my $opts     = shift // [];
    my $fork     = shift;

    my $name = $self->name;

    $self->statemap->{$cmd} && !(grep { $self->is($_) } @{$self->statemap->{$cmd}}) && do {
        $self->log->warn("WARNING: cannot '$cmd' $name. "
            . "$name is not " . join (' or ', @{$self->statemap->{$cmd}}) . '.');
        return 0;
    };

    $self->utils->exec('zoneadm', [ '-z', $name, $cmd, @$opts ],
        "cannot $cmd zone $name", $fork);
};

# attributes
has log     => sub { Mojo::Log->new(level => 'debug') };
has zones   => sub { Zadm::Zones->new(log => shift->log) };
has utils   => sub { Zadm::Utils->new(log => shift->log) };
has image   => sub { Zadm::Image->new(log => shift->log) };
has sv      => sub { Zadm::Validator->new(log => shift->log) };
has dp      => sub { Data::Processor->new(shift->schema) };
has name    => sub { Mojo::Exception->throw("ERROR: zone name must be specified on instantiation.\n") };
has config  => sub { my $self = shift; return $self->exists ? $self->$getConfig : $self->template };
has oldConf => sub { {} };
#has brand  => sub { shift->config->{brand} };
has brand   => sub { lc ((split /::/, ref shift)[-1]) };
has socket  => sub { my $self = shift; Mojo::Exception->throw('ERROR: no socket available for brand ' . $self->brand . ".\n") };
has public  => sub { [] };
has opts    => sub { {} };
has smod    => sub { my $mod = ref shift; $mod =~ s/Zone/Schema/; $mod };
has exists  => sub { my $self = shift; $self->zones->exists($self->name) };
# TODO: not all brands have a logfile, yet.
has logfile => sub { shift->config->{zonepath} . '/root/tmp/init.log' };
has valid   => sub { 0 };

has schema  => sub {
    my $self = shift;

    my $mod = $self->smod;
    return do {
        # fall back to generic schema if there is no brand specific
        eval "require $mod" || do {
            $mod = __PACKAGE__;
            $mod =~ s/Zone/Schema/;
            eval "require $mod";
        };
        $mod->new(sv => $self->sv)->schema;
    };
};

has resmap => sub {
    my $self = shift;

    return $self->utils->genmap(
        [ grep { exists $self->schema->{$_}->{members} } keys %{$self->schema} ]
    );
};

has createpropmap => sub {
    my $self = shift;

    return $self->utils->genmap($self->createprop);
};

# public methods
sub decodeProp {
    my $self = shift;
    my ($res, $prop, $val) = @_;

    my ($_prop, $_val) = $val =~ /name=([^,]+),value="([^"]+)"/;

    ($prop, $val) = ($_prop, $_val)
        if ($res eq 'net' && $_prop && exists $self->schema->{$res}->{members}->{$_prop}
            && $self->schema->{$res}->{members}->{$_prop}->{'x-netprop'});

    return ($prop, $val);
}

sub encodeProp {
    my $self = shift;
    my ($res, $prop, $val) = @_;

    return ('set', $prop, '=', q{"} . $self->$setVal($val) . q{"}, ';')
        if ($res ne 'net' || (exists $self->schema->{$res}->{members}->{$prop}
            && !$self->schema->{$res}->{members}->{$prop}->{'x-netprop'}));

    $val = ref $val eq 'ARRAY' ? "(name=$prop,value=\"" . join (',', @$val) . '")'
         : "(name=$prop,value=\"$val\")";

    return (qw(add property), $val, ';');
}

sub getPostProcess {
    my $self = shift;
    my $cfg  = shift;

    my $schema = $self->schema;

    for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
        my $name = $cfg->{attr}->[$i]->{name};

        next if !$self->$resIsAttr($name);

        $cfg->{$name} = exists $schema->{$name} && $schema->{$name}->{array}
                      ? [ split /,/, $cfg->{attr}->[$i]->{value} ]
                      : $cfg->{attr}->[$i]->{value};

        splice @{$cfg->{attr}}, $i, 1;
    }
    # check if attr is empty. if so remove it
    delete $cfg->{attr} if !@{$cfg->{attr}};

    # TODO: adding support for rctls (by now just aliased rctls are supported)
    delete $cfg->{rctl};

    return $cfg;
}

sub setPreProcess {
    my $self = shift;
    my $cfg  = shift;

    for my $res (keys %$cfg) {
        next if !$self->$resIsAttr($res);

        my %elem = (
            name => $res,
            type => 'string',
        );

        $elem{value} = ref $cfg->{$res} eq 'ARRAY'
                     ? join (',', @{$cfg->{$res}})
                     : $cfg->{$res};

        push @{$cfg->{attr}}, { %elem };
        delete $cfg->{$res};
    }

    return $cfg;
}

sub validate {
    my $self = shift;
    my $config = shift // $self->config;

    $self->valid(0);

    my $ec = $self->dp->validate($config);
    $ec->count and Mojo::Exception->throw(join ("\n", map { $_->stringify } @{$ec->{errors}}) . "\n");

    return $self->valid(1);
}

sub setConfig {
    return shift->$setConfig(shift);
}

sub getOptions {
    my $self = shift;
    my $oper = shift;

    return [] if !exists $self->options->{$oper};

    return [ map { $self->options->{$oper}->{$_}->{getopt} } keys %{$self->options->{$oper}} ];
}

sub checkMandOptions {
    my $self = shift;
    my $oper = shift;

    $self->options->{$oper}->{$_}->{mand} && !$self->opts->{$_}
        and return 0 for keys %{$self->options->{$oper}};

    return 1;
}

sub state {
    my $self = shift;

    return $self->zones->list->{$self->name}->{state};
}

sub is {
    my $self  = shift;
    my $state = shift // return 1;

    return $self->state eq $state;
}

sub isPublic {
    my $self   = shift;
    my $method = shift;

    return grep { $_ eq $method } @{$self->public};
}

sub boot {
    shift->$zoneCmd('boot');
}

sub shutdown {
    # fork shutdown to the bg
    shift->$zoneCmd('shutdown', undef, 1);
}

sub reboot {
    # fork shutdown to the bg
    shift->$zoneCmd('shutdown', [ qw(-r) ], 1);
}

sub poweroff {
    shift->$zoneCmd('halt');
}

sub reset {
    my $self = shift;
    Mojo::Exception->throw('reset not available for brand ' . $self->brand . "\n");
}

sub nmi {
    my $self = shift;
    Mojo::Exception->throw('nmi not available for brand ' . $self->brand . "\n");
}

sub console {
    my $self = shift;

    my $name = $self->name;
    $self->utils->exec('zlogin', [ '-C', $name ],
        "cannot attach to $name zone console");
}

sub create {
    my $self  = shift;
    my $props = shift;

    my @cmd = ('-z', $self->name, qw(create -b ;));
    push @cmd, ('set', $_, '=', q{"} . $props->{$_} . q{"}, ';')
        for keys %$props;

    $self->utils->exec('zonecfg', \@cmd);
}

sub delete {
    my $self = shift;

    $self->utils->exec('zonecfg', [ '-z', $self->name, 'delete' ]);
}

sub install {
    shift->$zoneCmd('install', [ @_ ]);
}

sub uninstall {
    shift->$zoneCmd('uninstall');
}

sub remove {
    my $self = shift;
    my $opts = shift;

    my $name = $self->name;
    Mojo::Exception->throw("ERROR: cannot delete running zone '$name'\n")
        if $self->is('running');

    $self->state =~ /^(?:incomplete|installed)$/ && do {
        $self->log->debug("uninstalling zone '$name'");
        $self->uninstall;
    };
    $self->is('configured') && do {
        $self->log->debug("deleting zone '$name'");
        $self->delete;
    };
}

sub usage {
    pod2usage(-input => pod_where({-inc => 1}, ref shift), 1);
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
