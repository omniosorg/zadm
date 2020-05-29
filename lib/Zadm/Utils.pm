package Zadm::Utils;
use Mojo::Base -base;

use POSIX qw(isatty);
use Mojo::Exception;
use JSON::PP; # for pretty encoding and 'relaxed' decoding
use Mojo::Log;
use Mojo::File;
use IPC::Open3;
use File::Spec;
use File::Temp;
use Text::ParseWords qw(shellwords);
use String::ShellQuote qw(shell_quote);

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
    pkg         => '/usr/bin/pkg',
    curl        => '/usr/bin/curl',
    cat         => '/usr/bin/cat',
    # TODO: OmniOS r30/r32 ship socat from the extra repository
    socat       => -x '/usr/bin/socat' ? '/usr/bin/socat' : '/opt/ooce/bin/socat',
    nc          => '/usr/bin/nc',
    pv          => '/usr/bin/pv',
    gzip        => -x '/opt/ooce/bin/pigz' ? '/opt/ooce/bin/pigz' : '/usr/bin/gzip',
    bzip2       => -x '/opt/ooce/bin/pbzip2' ? '/opt/ooce/bin/pbzip2' : '/usr/bin/bzip2',
    # TODO: for now we just map suffixes to the appropriate program
    # this should be enhanced. currently only used in zfsRecv
    gz          => -x '/opt/ooce/bin/pigz' ? '/opt/ooce/bin/pigz' : '/usr/bin/gzip',
    bz2         => -x '/opt/ooce/bin/pbzip2' ? '/opt/ooce/bin/pbzip2' : '/usr/bin/bzip2',
    xz          => '/usr/bin/xz',
    pager       => $ENV{PAGER} || '/usr/bin/less -eimnqX',
    domainname  => '/usr/bin/domainname',
    dispadmin   => '/usr/sbin/dispadmin',
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

    my $modified = $file->stat->mtime;

    local $@;
    eval {
        local $SIG{__DIE__};

        $self->exec('editor', [ $fh->filename ]);
    };
    if ($@) {
        # a return value of -1 indicats the editor could not be executed
        Mojo::Exception->throw("$@\n") if $? == -1;

        return (0, $json);
    }

    $json = $file->slurp;

    $modified = $file->stat->mtime != $modified;

    return ($modified, $json);
};

# public methods
sub readProc {
    my $self = shift;
    my $cmd  = shift;
    my $args = shift || [];

    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = (shellwords($CMDS{$cmd}), @{$ENVARGS{$cmd}}, @$args);
    $self->log->debug("@cmd");

    open my $devnull, '>', File::Spec->devnull;
    my $pid = open3(undef, my $stdout, $devnull, @cmd);

    chomp (my @read = <$stdout>);

    waitpid $pid, 0;

    return \@read;
}

sub exec {
    my $self = shift;
    my $cmd  = shift;
    my $args = shift || [];
    my $err  = shift || "executing '$cmd'";
    my $fork = shift;

    Mojo::Exception->throw("ERROR: command '$cmd' not defined.\n")
        if !exists $CMDS{$cmd};

    my @cmd = (shellwords($CMDS{$cmd}), @{$ENVARGS{$cmd}}, @$args);
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

sub zfsRecv {
    my $self = shift;
    my $file = shift;
    my $ds   = shift;

    my ($suf) = $file =~ /\.([^.]+)$/;

    Mojo::Exception->throw("ERROR: compression algorithm for suffix '$suf' unknown.\n")
        if $suf && !exists $CMDS{$suf};

    my $cmd = join ' ',
        shell_quote(shellwords($CMDS{$suf // 'cat'}, $suf ? qw(-dck) : ())),
        shell_quote($file),
        '|', shell_quote(shellwords($CMDS{pv})), '|',
        shell_quote(shellwords($CMDS{zfs}), qw(recv -Fv)),
        shell_quote($ds);

    $self->log->debug($cmd);

    system $cmd and Mojo::Exception->throw("ERROR: receiving zfs stream: $!\n");
}

sub encodeJSON {
    my $self = shift;
    my $data = shift;

    return JSON::PP->new->pretty->canonical(1)->encode($data);
}

sub edit {
    my $self = shift;
    my $zone = shift;
    my $prop = shift;

    # backup current zone XML so it can be restored when things get hairy
    my $backcfg;
    my $backmod;
    my $zonexml = "$ZPATH/" . $zone->name . '.xml';

    my $xml = Mojo::File->new($zonexml);
    if (-r $zonexml) {
        $self->log->debug("backing up current zone config from $zonexml");

        $backmod = $xml->stat->mtime;
        $backcfg = $xml->slurp
    }

    my $json = $self->encodeJSON($zone->config)
        if !$prop && ($self->isaTTY || ($ENV{__ZADMTEST} && !$ENV{__ZADM_NOTTY}));

    my $cfgValid = 0;

    while (!$cfgValid) {
        (my $mod, $json) = $prop                                         ? (1, '')
                         : $self->isaTTY
                            || ($ENV{__ZADMTEST} && !$ENV{__ZADM_NOTTY}) ? $self->$edit($json)
                         :                                                 (1, join ("\n", @{$self->getSTDIN}));

        if (!$mod) {
            if ($zone->exists) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    $xml->spurt($backcfg);

                    return 0;
                }

                return 1;
            }

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
            my $cfg = $prop ? { %{$zone->config}, %$prop } : JSON::PP->new->relaxed(1)->decode($json);
            $cfgValid = $zone->setConfig($cfg);
        };
        if ($@) {
            print $@;

            my $check;
            # TODO: is there a better way of handling this?
            if (!$self->isaTTY || $prop || $ENV{__ZADMTEST}) {
                $check = 'no';
            } else {
                print 'Do you want to retry [Y/n]? ';
                chomp ($check = <STDIN>);
            }

            if ($check =~ /^no?$/i) {
                # restoring the zone XML config since it was changed but something went wrong
                if ($backmod && $backmod != $xml->stat->mtime) {
                    $self->log->warn('WARNING: restoring the zone config.');
                    Mojo::File->new($zonexml)->spurt($backcfg);
                }

                return 0;
            }
        }
    }

    return 1;
}

sub getZfsProp {
    my $self = shift;
    my $ds   = shift;
    my $prop = shift // [];

    return {} if !@$prop;

    my $vals = $self->readProc('zfs', [ qw(get -H -o value), join (',', @$prop), $ds ]);

    return { map { $prop->[$_] => $vals->[$_] } (0 .. $#$prop) };
}

sub domain {
    my $self = shift;

    my %domain;

    my ($domain) = $self->readProc('domainname')->[0] =~ /^\s*(\S+)/;

    -r '/etc/resolv.conf' && do {
        open my $fh, '<', '/etc/resolv.conf'
            or Mojo::Exception->throw("ERROR: cannot read /etc/resolv.conf: $!\n");

        while (<$fh>) {
            my ($key, $val) = /^\s*(\S+)\s+(\S+)/
                or next;

            for ($key) {
                /^nameserver$/ && do {
                    push @{$domain{resolvers}}, $val;

                    last;
                };
                /^domain$/ && do {
                    $domain{'dns-domain'} = $val;

                    last;
                };
                /^search$/ && do {
                    $domain{'dns-domain'} ||= $val;

                    last;
                };
            }
        }
    };

    $domain{'dns-domain'} = $domain if $domain;

    return \%domain;
}

sub scheduler {
    my $self = shift;

    my $dispadmin = $self->readProc('dispadmin', [ qw(-d) ]);

    return { 'cpu-shares' => 1 } if grep { /^FSS/ } @$dispadmin;
    return {};
}

sub loadTemplate {
    my $self  = shift;
    my $file  = shift;
    my $name  = shift;

    my $template = Mojo::File->new($file)->slurp;
    # TODO: add handler for more modular transforms, for now we just support __ZONENAME__
    $template =~ s/__ZONENAME__/$name/g if $name;

    # TODO: add proper error handling
    return JSON::PP->new->relaxed(1)->decode($template);
}

sub getOverLink {
    my $self = shift;

    my $dladm = $self->readProc('dladm', [ qw(show-link -p -o), 'link,class' ]);
    return [ map { /^([^:]+):(?:phys|etherstub|overlay)/ } @$dladm ];
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

