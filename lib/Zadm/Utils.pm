package Zadm::Utils;
use Mojo::Base -base;

use POSIX qw(isatty);
use Mojo::Exception;
use JSON::PP; # for pretty encoding and 'relaxed' decoding
use Mojo::Log;
use File::Temp;
use Text::ParseWords qw(shellwords);

# commands
my %CMDS = (
    zoneadm     => '/usr/sbin/zoneadm',
    zonecfg     => '/usr/sbin/zonecfg',
    zlogin      => '/usr/sbin/zlogin',
    zonename    => '/usr/bin/zonename',
    bhyvectl    => '/usr/sbin/bhyvectl',
    dladm       => '/usr/sbin/dladm',
    editor      => $ENV{VISUAL} || $ENV{EDITOR} || '/usr/bin/vi',
    zfs         => '/usr/sbin/zfs',
    curl        => '/usr/bin/curl',
    socat       => '/usr/bin/socat',
);

my %ENVARGS = map {
    $_ => [ shellwords($ENV{'__ZADM_' .  uc ($_) . '_ARGS'} // '') ]
} keys %CMDS;

my $ZPATH = ($ENV{__ZADM_ALTROOT} // '') . '/etc/zones';

# attributes
has log => sub { Mojo::Log->new(level => 'debug') };

# private methods
my $edit = sub {
    my $self = shift;
    my $json = shift;

    my $fh = File::Temp->new(SUFFIX => '.json');
    close $fh;

    my $file = Mojo::File->new($fh->filename);
    $file->spurt($json);

    my $modified = (stat $fh->filename)[9];

    $self->exec('editor', [ $fh->filename ]);

    $json = $file->slurp;

    $modified = (stat $fh->filename)[9] != $modified;

    return ($modified, $json);
};

# public methods
sub pipe {
    my $self = shift;
    my $cmd  = shift;
    my $args = shift || [];
    my $err  = shift || "executing '$cmd'";
    my $dir  = shift || '-|';

    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = ($CMDS{$cmd}, @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug("@cmd");

    open my $pipe, $dir, @cmd
        or Mojo::Exception->throw("ERROR: $err: $!\n");

    return $pipe;
}

sub exec {
    my $self = shift;
    my $cmd  = shift;
    my $args = shift || [];
    my $err  = shift || "executing '$cmd'";
    my $fork = shift;

    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = ($CMDS{$cmd}, @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug("@cmd");

    if ($fork) {
        if (defined (my $pid = fork)) {
            # exec should never return unless there was an error
            $pid || exec (@cmd)
                or Mojo::Exception->throw("ERROR: $err: $!\n");
        }
    }
    else {
        system (@cmd) && Mojo::Exception->throw("ERROR: $err: $!\n");
    }
}

sub encodeJSON {
    my $self = shift;
    my $data = shift;

    return JSON::PP->new->pretty->canonical(1)->encode($data);
}

sub edit {
    my $self = shift;
    my $zone = shift;

    # backup current zone XML so it can be restored when things get hairy
    my $backcfg;
    my $backmod;
    my $zonexml = "$ZPATH/" . $zone->name . '.xml';

    if (-r $zonexml) {
        $self->log->debug("backing up current zone config from $zonexml");

        $backmod = (stat $zonexml)[9];
        $backcfg = Mojo::File->new($zonexml)->slurp;
    }

    my $json = $self->encodeJSON($zone->config);

    my $cfgValid = 0;

    while (!$cfgValid) {
        (my $mod, $json) = $self->$edit($json);

        if (!$mod) {
            return 1 if $zone->exists;

            my $check;
            # TODO: is there a better way of handling this?
            if ($ENV{__ZADMTEST}) {
                $check = 'yes';
            } else {
                print "You did not make any changes to the default configuration,\n"
                    . 'do you want to create the zone with all defaults [Y/n]? ';
                chomp ($check = <STDIN>);
            }

            return 0 if $check =~ /^no?$/i;
        }

        local $@;
        eval {
            local $SIG{__DIE__};

            $self->log->debug("validating config");
            $cfgValid = $zone->setConfig(JSON::PP->new->relaxed(1)->decode($json));
        };
        if ($@) {
            my $check;

            # TODO: is there a better way of handling this?
            if ($ENV{__ZADMTEST}) {
                $check = 'no';
            } else {
                print 'Do you want to retry [Y/n]? ';
                chomp ($check = <STDIN>);
            }

            if ($check =~ /^no?$/i) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != (stat $zonexml)[9]) {
                    $self->log->debug("restoring the zone config from $zonexml");
                    Mojo::File->new($zonexml)->spurt($backcfg);
                }

                return 0;
            }
        }
    }

    return 1;
}

sub loadJSON {
    my $self = shift;
    my $file = shift;

    # TODO: add proper error handling
    return JSON::PP->new->relaxed(1)->decode(Mojo::File->new($file)->slurp);
}

sub isVirtual {
    my $method = (caller(1))[3];

    Mojo::Exception->throw("ERROR: '$method' is a pure virtual method and must be implemented in a derived class.\n");
}

sub isaTTY {
    my $self = shift;
    return isatty(*STDIN);
}

sub getSTDIN {
    my $self = shift;
    return $self->isaTTY() ? [] : [ split /[\r\n]+/, do { local $/; <STDIN>; } ];
}

sub genmap {
    my $self = shift;
    my $arr  = shift;

    return { map { $_ => undef } @$arr };
}

1;

