package Zadm::Zone::base;
use Mojo::Base -base;

use Mojo::File;
use Mojo::Log;
use Mojo::Home;
use Mojo::Loader qw(load_class);
use Mojo::Util qw(class_to_path);
use Data::Processor;
use Pod::Text;
use Pod::Usage;
use Storable qw(dclone freeze);
use Term::ANSIColor qw(colored);
use Zadm::Zones;
use Zadm::Utils;
use Zadm::Image;
use Zadm::Validator;

# constants/definitions
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
        autoboot    => 'false',
        net         => [{
            physical     => "${name}0",
            'global-nic' => $self->utils->getOverLink->[0],
        }],
        %{$self->utils->domain},
        %{$self->utils->scheduler},
    }
};
has options => sub {
    {
        fw => {
            edit   => {
                getopt => 'edit|e=s',
            },
            map {
                $_ => { getopt =>  "$_|" . substr $_, 0, 1 }
            } qw(reload disable monitor top)
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
    $val =~ s/^\s*\[// && $val =~ s/\]\s*$//;

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
    $val =~ s/^\s*\(// && $val =~ s/\)\s*$//;

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

    # remove leading and trailing quotes
    $val =~ s/^\s*"// && $val =~ s/"\s*$//;

    return $self->$propIsArray($res, $prop) ? $self->$getArray($val)
         : $self->$propIsHash($res, $prop)  ? $self->$getHash($val)
         : $val;
};

my $setVal = sub {
    my $self = shift;
    my $prop = shift;

    return ref $prop eq ref [] ? $self->$setArray($prop)
         : ref $prop eq ref {}  ? $self->$setHash($prop)
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

my $delResource = sub {
    my $self  = shift;
    my $res   = shift;

    my $name = $self->name;
    my @cmd  = ('-z', $name, qw(remove -F), $res);

    $self->utils->exec('zonecfg', \@cmd, "cannot delete resource '$res' from zone '$name'");
};

my $setProperty = sub {
    my $self = shift;
    my $prop = shift;

    my $name = $self->name;

    my @cmd = ('-z', $name, 'set', $prop, '=',
        q{"} . $self->$setVal($self->config->{$prop}) . q{"});

    $self->utils->exec('zonecfg', \@cmd, "cannot set property '$prop'");
};

my $decodeProp = sub {
    my $self = shift;
    my ($res, $prop, $val) = @_;

    my ($_prop, $_val) = $val =~ /name=([^,]+),value="([^"]+)"/;

    ($prop, $val) = ($_prop, $_val)
        if ($res eq 'net' && $_prop && exists $self->schema->{$res}->{members}->{$_prop}
            && $self->schema->{$res}->{members}->{$_prop}->{'x-netprop'});

    return ($prop, $val);
};

my $encodeProp = sub {
    my $self = shift;
    my ($res, $prop, $val) = @_;

    return ('set', $prop, '=', q{"} . $self->$setVal($val) . q{"}, ';')
        if ($res ne 'net' || (exists $self->schema->{$res}->{members}->{$prop}
            && !$self->schema->{$res}->{members}->{$prop}->{'x-netprop'}));

    $val = ref $val eq ref [] ? qq{(name=$prop,value="} . join (',', @$val) . '")'
         : qq{(name=$prop,value="$val")};

    return (qw(add property), $val, ';');
};

my $clearProperty = sub {
    my $self = shift;
    my $prop = shift;

    my $name = $self->name;

    my @cmd = ('-z', $name, 'clear', $prop);

    $self->utils->exec('zonecfg', \@cmd, "cannot clear property $prop");
};

my $clearResources = sub {
    my $self    = shift;
    my $oldConf = shift;

    # using Storable which is in core for a deep compare
    # make sure the hash keys are sorted for serialisation
    $Storable::canonical = 1;
    # TODO: adding support for rctls (for now just aliased rctls are supported)
    for my $res (@{$self->oldres}) {
        next if $res eq 'rctl' || !$self->$isRes($res);

        if (!$self->config->{$res} || freeze($oldConf->{$res}) ne freeze($self->config->{$res})) {
            $self->$delResource($res);
        }
        else {
            delete $self->config->{$res};
        }
    }
};

my $clearSimpleAttrs = sub {
    my $self = shift;

    $self->$clearProperty($_) for grep {
        !$self->$isRes($_) && !exists $self->config->{$_}
    } @{$self->oldres};
};

my $getConfig = sub {
    my $self = shift;

    my $config = {};

    return {} if !$self->zones->exists($self->name);

    my $props = $self->utils->readProc('zonecfg', ['-z', $self->name, 'info']);

    my $res;
    for my $line (@$props) {
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
            ($prop, $val) = $self->$decodeProp($res, $prop, $val);
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
    $self->oldres([ keys %$config ]) if !$self->oldres;

    return $self->getPostProcess($config);
};

my $setConfig = sub {
    my $self   = shift;
    my $config = shift;

    # get current config so we can check for changes
    # deep cloning the data structure since pre-process changes in-place
    # although we are setting a new config, both data structures
    # might share common elements resulting in pre-processing
    # the same data twice
    my $oldConf = dclone($self->config);
    $self->setPreProcess($oldConf);

    # validate new config
    $self->validate($config);

    # we don't support brand changes
    Mojo::Exception->throw("ERROR: brand cannot be changed from '"
        . $self->config->{brand} . "' to '" . $config->{brand} . ".\n")
        if $self->config->{brand} ne $config->{brand};

    # set new config
    $self->config($config);
    $self->setPreProcess($self->config);

    if ($self->exists) {
        # clean up all existing resources
        $self->$clearResources($oldConf);
        # clear simple attributes which have been removed
        $self->$clearSimpleAttrs;
    }
    else {
        $self->create({ map { $_ => $config->{$_} } @{$self->createprop} });
    }

    my $installed = !$self->is('configured');
    for my $prop (keys %{$self->config}) {
        $self->log->debug("processing property '$prop'");

        # skip props that cannot be changed once the zone is installed
        next if $installed && exists $self->createpropmap->{$prop};

        if (ref $self->config->{$prop} eq ref []) {
            $self->log->debug("property '$prop' is a resource array");

            $self->addResource($prop, $_) for (@{$self->config->{$prop}});
        }
        elsif ($self->$isRes($prop)) {
            $self->log->debug("property '$prop' is a resource");

            $self->addResource($prop, $self->config->{$prop});
        }
        else {
            next if !$self->config->{$prop}
                || ($oldConf->{$prop} && $oldConf->{$prop} eq $self->config->{$prop});

            $self->log->debug("property '$prop' changed: " . ($oldConf->{$prop} // '(none)') . ' -> '
                . $self->config->{$prop});

            $self->$setProperty($prop);
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
            . "$name is " . $self->state . ' and '
            . 'not ' . join (' or ', @{$self->statemap->{$cmd}}) . '.');
        return 0;
    };

    $self->utils->exec('zoneadm', [ '-z', $name, $cmd, @$opts ],
        "cannot $cmd zone $name", $fork);
};

# private static methods

# not using pod_write from Data::Processor as we want a different formatting
my $genDoc;
$genDoc = sub {
    my $schema = shift;
    my $over   = shift // 0;

    my @doc;
    for my $attr (sort {
        # mandatory attributes first
        ($schema->{$a}->{optional} // 0) <=> ($schema->{$b}->{optional} // 0)
        ||
        $a cmp $b
    } keys %$schema) {
        my $str = $attr;
        $str .= ' (optional)' if $schema->{$attr}->{optional};
        $str .= ':';
        $str .= ' array of' if $schema->{$attr}->{array};
        $str .= exists $schema->{$attr}->{members}
            ? ' resource containing the following attributes:'
            : ' ' . ($schema->{$attr}->{description} || '<description missing>');

        push @doc, $over ? "  $str" : ($str, '');

        if (exists $schema->{$attr}->{members}) {
            push @doc, ('', '=over', '');
            push @doc, @{$genDoc->($schema->{$attr}->{members}, 1)};
            push @doc, ('', '=back', '');
        }
    }

    return \@doc;
};

# attributes
has log     => sub { Mojo::Log->new(level => 'debug') };
has zones   => sub { Zadm::Zones->new(log => shift->log) };
has utils   => sub { Zadm::Utils->new(log => shift->log) };
has image   => sub { Zadm::Image->new(log => shift->log) };
has sv      => sub { Zadm::Validator->new(log => shift->log) };
has dp      => sub { Data::Processor->new(shift->schema) };
has name    => sub { Mojo::Exception->throw("ERROR: zone name must be specified on instantiation.\n") };
has oldres  => sub { 0 };
has brand   => sub { lc ((split /::/, ref shift)[-1]) };
has public  => sub { [ qw(login fw) ] };
has opts    => sub { {} };
has smod    => sub { my $mod = ref shift; $mod =~ s/Zone/Schema/; $mod };
has exists  => sub { my $self = shift; $self->zones->exists($self->name) };
has valid   => sub { 0 };

has logfile => sub {
    my $self = shift;

    my $zlog = $self->config->{zonepath} . '/root/tmp/init.log';
    return -r $zlog ? $zlog : $self->config->{zonepath} . '/log/zone.log';
};

has config  => sub {
    my $self = shift;
    return $self->$getConfig if $self->exists;

    return {
        %{$self->template},
        zonename => $self->name,
        brand    => $self->brand,
    }
};

has schema  => sub {
    my $self = shift;

    my $mod = $self->smod;
    return do {
        # fall back to generic schema if there is no brand specific
        load_class($mod) && do {
            $mod = __PACKAGE__;
            $mod =~ s/Zone/Schema/;
            load_class($mod)
                and Mojo::Exception->throw("ERROR: cannot load schema class '$mod'.\n");
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
sub addResource {
    my $self  = shift;
    my $res   = shift;
    my $props = shift;

    my $name = $self->name;
    my @cmd  = ('-z', $name, 'add', $res, ';');

    push @cmd, $self->$encodeProp($res, $_, $props->{$_}) for keys %$props;

    push @cmd, qw(end);

    $self->utils->exec('zonecfg', \@cmd, "cannot config zone $name");
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

    # TODO: adding support for rctls (for now just aliased rctls are supported)
    delete $cfg->{rctl};

    return $cfg;
}

sub setPreProcess {
    my $self = shift;
    my $cfg  = shift;

    # sort the attr resources by name for deep compare
    for my $res (sort keys %$cfg) {
        next if !$self->$resIsAttr($res);

        my %elem = (
            name => $res,
            type => 'string',
        );

        $elem{value} = ref $cfg->{$res} eq ref []
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

    $self->zones->refresh;
    my $zones = $self->zones->list;

    return exists $zones->{$self->name} ? $zones->{$self->name}->{state} : 'unknown';
}

sub is {
    my $self  = shift;
    my $state = shift // return 0;

    return $self->state eq $state;
}

sub isPublic {
    my $self   = shift;
    my $method = shift;

    return !!grep { $_ eq $method } @{$self->public};
}

sub isSimpleProp {
    my $self = shift;
    my $prop = shift;

    $self->$isProp($prop)
        or Mojo::Exception->throw("ERROR: property '$prop' does not exist for brand " . $self->brand . "\n");

    return !$self->$isRes($prop) && !$self->$resIsArray($prop);
}

sub boot {
    my $self  = shift;
    my $cOpts = shift;

    # fork boot to the bg if we are about to attach to the console
    $self->$zoneCmd('boot', undef, $self->opts->{console});

    $self->console($cOpts) if $self->opts->{console};
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

    $self->poweroff;
    $self->boot;
}

sub login {
    my $self = shift;

    my $name = $self->name;

    Mojo::Exception->throw("ERROR: '$name' is not running, cannot login.\n")
        if !$self->is('running');

    $self->utils->exec('zlogin', [ $name ], "cannot login to $name");
}

sub console {
    my $self  = shift;
    my $cOpts = shift // [];

    my $name = $self->name;
    $self->utils->exec('zlogin', [ '-C', @$cOpts, $name ],
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
    my $self = shift;

    # TODO centralise and improve this
    $ENV{__ZADM_ALTROOT} && do {
        $self->log->warn('Cannot install a zone inside an alternate root.');
        return 1;
    };
    $self->$zoneCmd('install', [ @_ ]);
}

sub uninstall {
    my $self = shift;

    # TODO centralise and improve this
    $ENV{__ZADM_ALTROOT} && do {
        $self->log->warn('Cannot uninstall a zone inside an alternate root.');
        return 1;
    };
    $self->$zoneCmd('uninstall');
}

sub remove {
    my $self = shift;

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

sub zStats {
    my $self = shift;

    return {
        RAM    => $self->config->{'capped-memory'}->{physical} // '-',
        CPUS   => $self->config->{'capped-cpu'}->{ncpus} // '-',
        SHARES => $self->config->{'cpu-shares'} // '1',
    };
}

sub usage {
    my $mod = ref shift;

    pod2usage(-input => Mojo::File->new(Mojo::Home->new->detect($mod),
        'lib', class_to_path($mod))->to_abs->to_string, 1);
}

sub doc {
    my $self = shift;

    my $opts = $self->opts;

    my $schema;
    my $header;
    if ($opts->{attr}) {
        Mojo::Exception->throw("ERROR: attribute '" . $opts->{attr}
            . "' does not exist for brand '" . $self->brand . "'.\n")
            if !exists $self->schema->{$opts->{attr}};

        $schema = { $opts->{attr} => $self->schema->{$opts->{attr}} };
        $header = '=head1 ' . $self->brand . ' brand ' . $opts->{attr} . ' attribute';
    }
    else {
        $schema = $self->schema;
        $header = '=head1 ' . $self->brand . ' brand attributes';
    }

    my $pod = Pod::Text->new;

    $pod->parse_lines(
        $header,
        '',
        @{$genDoc->($schema)},
        undef
    );
}

sub fw {
    my $self = shift;

    my $name = $self->name;
    my $opts = $self->opts;

    if ($opts->{edit}) {
        $self->usage if $opts->{edit} !~ /^(?:ipf6?|ipnat)$/;

        my $f = Mojo::File->new($self->config->{zonepath}, 'etc', $opts->{edit} . '.conf');
        my $mtime = -e $f ? $f->stat->mtime : 0;

        local $@;
        eval {
            local $SIG{__DIE__};

            # create config directory if it does not yet exist
            $f->dirname->make_path({ mode => 0700 });
        };
        Mojo::Exception->throw("ERROR: cannot access/create '" . $f->dirname . "': $!\n") if $@;

        if ($self->utils->isaTTY) {
            $self->utils->exec('editor', [ $f ]);
        }
        else {
            # ipf requires a trailing newline
            $f->spurt(join ("\n", @{$self->utils->getSTDIN}), "\n");
        }

        return if !-e $f || $mtime == $f->stat->mtime;
        $opts->{reload} = 1;
    }

    return if !$self->is('running');

    if ($opts->{disable}) {
        $self->utils->exec('ipf', [ '-GD', $name ]);

        return;
    }

    if ($opts->{reload}) {
        $self->log->debug("reloading ipf/ipnat for zone '$name'...");

        $self->utils->exec('ipf', [ '-GE', $name ]);

        my $f = Mojo::File->new($self->config->{zonepath}, 'etc', 'ipf.conf');
        $self->utils->exec('ipf', [ qw(-GFa -f), $f, $name ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipf');

        $f = $f->sibling('ipf6.conf');
        $self->utils->exec('ipf', [ qw(-6GFa -f), $f, $name ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipf6');

        $f = $f->sibling('ipnat.conf');
        $self->utils->exec('ipnat', [ qw(-CF -G), $name, '-f', $f ])
            if -r $f && (!$opts->{edit} || $opts->{edit} eq 'ipnat');

        $self->utils->exec('ipf', [ '-Gy', $name ]);

        return;
    }

    if ($opts->{monitor}) {
        # ignore the return code of ipmon since ^C'ing it will return non-null
        $self->utils->exec('ipmon', [ '-aG', $name ], undef, undef, 1);

        return;
    }

    if ($opts->{top}) {
        $self->utils->exec('ipfstat', [ '-tG', $name ]);

        return;
    }

    my %statemap = (
        'pass'  => colored('pass', 'green'),
        'block' => colored('block', 'red'),
    );
    my %ipfheaders = (
        '-iG'   => colored("==> inbound IPv4 ipf rules for $name:", 'ansi208'),
        '-i6G'  => colored("==> inbound IPv6 ipf rules for $name:", 'ansi208'),
        '-oG'   => colored("==> outbound IPv4 ipf rules for $name:", 'ansi208'),
        '-o6G'  => colored("==> outbound IPv6 ipf rules for $name:", 'ansi208'),
    );

    for my $ipf (qw(-iG -i6G -oG -o6G)) {
        my $rules = $self->utils->readProc('ipfstat', [ $ipf, $name ]);
        next if !@$rules;

        print $ipfheaders{$ipf} . "\n";
        for my $line (@$rules) {
            $line =~ s/$_/$statemap{$_}/ for keys %statemap;

            print "$line\n";
        }
        print "\n";
    }

    my $rules = $self->utils->readProc('ipnat', [ '-lG', $name ]);
    my @rules;
    for my $rule (@$rules) {
        next if !$rule || $rule =~ /active\s+MAP/;
        last if $rule =~ /active\s+sessions/;

        push @rules, $rule;
    }
    return if !@rules;

    print colored("==> ipnat rules for $name:", 'ansi208') . "\n";
    print join "\n", @rules;
    print "\n";
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-t <template_path>] <zone_name>
    delete <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-f] <zone_name>
    uninstall <zone_name>
    show [zone_name [property]]
    list
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    console [extra_args] <zone_name>
    log <zone_name>
    fw [-r] [-d] [-t] [-m] [-e ipf|ipf6|ipnat] <zone_name>
    help [-b <brand>]
    doc [-b <brand>] [-a <attribute>]
    man
    version

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

S<Dominik Hassler E<lt>hadfl@omniosce.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
