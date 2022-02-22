package Zadm::Zone::Bhyve;
use Mojo::Base 'Zadm::Zone::KVM', -signatures;

use Mojo::Exception;
use Mojo::File;

# reset public interface as the inherited list
# from KVM will have additional methods
has public   => sub { [ qw(efireset nmi vnc webvnc fw) ] };
has options  => sub($self) {
    return {
        %{$self->SUPER::options},
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
has vncattr  => sub($self) {
    return {
        map  { $_ => $self->schema->{vnc}->{members}->{$_}->{'x-vncbool'} }
        grep { exists $self->schema->{vnc}->{members}->{$_}->{'x-vncbool'} }
        keys %{$self->schema->{vnc}->{members}}
    };
};
has vnckeys  => sub($self) {
    return [
        sort {
            $self->schema->{vnc}->{members}->{$a}->{'x-vncidx'}
            <=>
            $self->schema->{vnc}->{members}->{$b}->{'x-vncidx'}
        } keys %{$self->vncattr}
    ];
};

# private methods
my $bhyveCtl = sub($self, $cmd) {
    my $name = $self->name;

    $self->is('running') || do {
        $self->log->warn("WARNING: cannot '$cmd' $name. "
            . "$name is not in running state.");
        return 0;
    };

    $self->utils->exec('bhyvectl', [ "--vm=$name", $cmd ],
        "cannot $cmd zone $name");
};

my $setVNCAttr = sub($self, $vnc = {}) {
    my @attrs;

    for my $attr (@{$self->vnckeys}) {
        if ($attr eq 'enabled') {
            push @attrs, $self->utils->boolIsTrue($vnc->{$attr}) ? 'on' : 'off';

            next;
        }

        push @attrs, !$vnc->{$attr}            ? ()
                     # boolean attr handling
                     : $self->vncattr->{$attr} ? ($self->utils->boolIsTrue($vnc->{$attr}) ? $attr : ())
                     # non-boolean attr handling
                     :                           "$attr=$vnc->{$attr}";
    }

    return join ',', @attrs;
};

# public methods
sub getPostProcess($self, $cfg) {
    $cfg->{$_} = [] for qw(ppt virtfs);

    # handle ppt/virtfs before the default getPostProcess
    if ($self->utils->isArrRef($cfg->{attr})) {
        ATTR: for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
            for ($cfg->{attr}->[$i]->{name}) {
                /^ppt\d+$/ && do {
                    unshift @{$cfg->{ppt}}, {
                        device => $cfg->{attr}->[$i]->{name},
                        state  => $cfg->{attr}->[$i]->{value},
                    };

                    last;
                };
                /^virtfs\d+$/ && do {
                    my ($name, $path, $ro) = split /,/, $cfg->{attr}->[$i]->{value}, 3;
                    $ro = $ro && $ro eq 'ro' ? 'true' : 'false';

                    unshift @{$cfg->{virtfs}}, {
                        name => $name // '',
                        path => $path // '',
                        ro   => $ro,
                    };

                    last;
                };
                /^vnc$/ && do {
                    $cfg->{vnc} = $self->sv->toVNCHash->($cfg->{attr}->[$i]->{value});

                    last;
                };

                # default
                next ATTR;
            }

            splice @{$cfg->{attr}}, $i, 1;
        }
    }

    $cfg = $self->SUPER::getPostProcess($cfg);

    # remove device for ppt
    if ($self->utils->isArrRef($cfg->{ppt}) && $self->utils->isArrRef($cfg->{device})) {
        for (my $i = $#{$cfg->{device}}; $i >= 0; $i--) {
            splice @{$cfg->{device}}, $i, 1
                if grep { $cfg->{device}->[$i]->{match} eq "/dev/$_->{device}" } @{$cfg->{ppt}};
        }
    }

    # remove lofs mounts for virtfs
    if ($self->utils->isArrRef($cfg->{virtfs}) && $self->utils->isArrRef($cfg->{fs})) {
        for (my $i = $#{$cfg->{fs}}; $i >= 0; $i--) {
            splice @{$cfg->{fs}}, $i, 1 if grep {
                $cfg->{fs}->[$i]->{dir} eq $_->{path}
                && $cfg->{fs}->[$i]->{special} eq $_->{path}
            } @{$cfg->{virtfs}};
        }
    }

    # remove ppt/device/virtfs/fs if empty
    $self->utils->isArrRef($cfg->{$_}) && !@{$cfg->{$_}} && delete $cfg->{$_} for qw(ppt device virtfs fs);

    return $cfg;
}

sub setPreProcess($self, $cfg) {
    # add device for ppt
    if ($self->utils->isArrRef($cfg->{ppt})) {
        for (my $i = 0; $i < @{$cfg->{ppt}}; $i++) {
            push @{$cfg->{attr}}, {
                name    => $cfg->{ppt}->[$i]->{device},
                type    => 'string',
                value   => $cfg->{ppt}->[$i]->{state},
            };

            push @{$cfg->{device}}, { match => "/dev/$cfg->{ppt}->[$i]->{device}" }
                if $self->utils->boolIsTrue($cfg->{ppt}->[$i]->{state});
        }

        delete $cfg->{ppt};
    }

    # add lofs for virtfs
    if ($self->utils->isArrRef($cfg->{virtfs})) {
        for (my $i = 0; $i < @{$cfg->{virtfs}}; $i++) {
            my $val  = join ',', $cfg->{virtfs}->[$i]->{name}, $cfg->{virtfs}->[$i]->{path};
            my $isRO = $self->utils->boolIsTrue($cfg->{virtfs}->[$i]->{ro});
            $val .= ',ro' if $isRO;

            push @{$cfg->{attr}}, {
                name    => "virtfs$i",
                type    => 'string',
                value   => $val,
            };

            # check whether a delegated dataset for path exists
            if ($self->utils->isArrRef($cfg->{dataset})) {
                my $ds = $self->utils->getMntDs($cfg->{virtfs}->[$i]->{path}, 0);

                next if $ds && grep { $ds =~ m!^\Q$_->{name}\E(?:/|$)! } @{$cfg->{dataset}};
            }

            # check whether a lofs mount for path exists
            if ($self->utils->isArrRef($cfg->{fs})) {
                next if grep { $_->{dir} eq $cfg->{virtfs}->[$i]->{path} } @{$cfg->{fs}};
            }

            # the user neither provided a delegated dataset nor a lofs mount
            # only add an automatic lofs mount if the path exists
            Mojo::Exception->throw(<<"HDEND"
ERROR: neither a delegated dataset nor a lofs mount for '$cfg->{virtfs}->[$i]->{path}'
have been provided; and the path does not exist.
HDEND
            ) if !-d $cfg->{virtfs}->[$i]->{path};

            # add lofs mount
            push @{$cfg->{fs}}, {
                dir     => $cfg->{virtfs}->[$i]->{path},
                options => [ qw(nodevices), $isRO ? qw(ro) : () ],
                special => $cfg->{virtfs}->[$i]->{path},
                type    => 'lofs',
            };
        }

        delete $cfg->{virtfs};
    }

    # handle VNC
    if ($cfg->{vnc}) {
        push @{$cfg->{attr}}, {
            name  => 'vnc',
            type  => 'string',
            value => $self->$setVNCAttr($cfg->{vnc}),
        };

        delete $cfg->{vnc};
    }

    return $self->SUPER::setPreProcess($cfg);
}

sub poweroff($self) {
    $self->$bhyveCtl('--force-poweroff');
}

sub reset($self) {
    $self->$bhyveCtl('--force-reset');
}

sub nmi($self) {
    $self->$bhyveCtl('--inject-nmi');
}

sub efireset($self) {
    Mojo::Exception->throw("ERROR: cannot reset EFI while zone is running\n")
        if $self->is('running');

    unlink Mojo::File->new($self->config->{zonepath}, qw(root etc uefivars))
        or Mojo::Exception->throw("ERROR: cannot reset EFI: $!\n");
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid|image_path_or_uri>] [-t <template_path>] <zone_name>
    delete [-f] <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-i <image_uuid|image_path_or_uri>] [-f] <zone_name>
    uninstall [-f] <zone_name>
    show [zone_name [property[,property]...]]
    list [-H] [-F <format>] [-b <brand>] [-s <state>] [zone_name]
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    pull <image_uuid>
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop [-c [extra_args]] <zone_name>
    restart [-c [extra_args]] <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    efireset <zone_name>
    nmi <zone_name>
    console [extra_args] <zone_name>
    vnc [-w] [<[bind_addr:]port>] <zone_name>
    webvnc [<[bind_addr:]port>] <zone_name>
    log <zone_name>
    fw [-r] [-d] [-t] [-m] [-e ipf|ipf6|ipnat] <zone_name>
    snapshot [-d] <zone_name> [<snapname>]
    rollback [-r] <zone_name> <snapname>
    help [-b <brand>]
    doc [-b <brand>] [-a <attribute>]
    man
    version

=head1 COPYRIGHT

Copyright 2022 OmniOS Community Edition (OmniOSce) Association.

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
