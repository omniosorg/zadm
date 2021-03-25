package Zadm::Zone::Bhyve;
use Mojo::Base 'Zadm::Zone::KVM', -signatures;

# reset public interface as the inherited list
# from KVM will have additional methods
has public  => sub { [ qw(nmi vnc fw) ] };
has options => sub($self) {
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

sub getPostProcess($self, $cfg) {
    $cfg->{ppt} = [];

    # handle ppt before the default getPostProcess
    if ($cfg->{attr} && ref $cfg->{attr} eq ref []) {
        for (my $i = $#{$cfg->{attr}}; $i >= 0; $i--) {
            next if $cfg->{attr}->[$i]->{name} !~ /^ppt\d+$/;

            push @{$cfg->{ppt}}, $cfg->{attr}->[$i]->{name};
            splice @{$cfg->{attr}}, $i, 1;
        }
    }

    $cfg = $self->SUPER::getPostProcess($cfg);

    # remove device for ppt
    if ($cfg->{ppt} && ref $cfg->{ppt} eq ref [] && $cfg->{device} && ref $cfg->{device} eq ref []) {
        for (my $i = $#{$cfg->{device}}; $i >= 0; $i--) {
            splice @{$cfg->{device}}, $i, 1
                if grep { $_ && $cfg->{device}->[$i]->{match} =~ m!^/dev/$_$! } @{$cfg->{ppt}};
        }
    }

    # remove ppt/device if empty
    $cfg->{$_} && ref $cfg->{$_} eq ref [] && !@{$cfg->{$_}} && delete $cfg->{$_} for qw(ppt device);

    return $cfg;
}

sub setPreProcess($self, $cfg) {
    # add device for ppt
    if ($cfg->{ppt} && ref $cfg->{ppt} eq ref []) {
        for (my $i = 0; $i < @{$cfg->{ppt}}; $i++) {
            next if !$cfg->{ppt}->[$i];

            push @{$cfg->{attr}}, {
                name    => $cfg->{ppt}->[$i],
                type    => 'string',
                value   => 'on',
            };

            push @{$cfg->{device}}, { match => "/dev/$cfg->{ppt}->[$i]" };
        }

        delete $cfg->{ppt};
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

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> [-i <image_uuid|image_path_or_uri>] [-t <template_path>] <zone_name>
    delete <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install [-i <image_uuid|image_path_or_uri>] [-f] <zone_name>
    uninstall <zone_name>
    show [zone_name [property]]
    list
    memstat
    list-images [--refresh] [--verbose] [-b <brand>] [-p <provider>]
    pull <image_uuid>
    vacuum [-d <days>]
    brands
    start [-c [extra_args]] <zone_name>
    stop <zone_name>
    restart <zone_name>
    poweroff <zone_name>
    reset <zone_name>
    nmi <zone_name>
    console [extra_args] <zone_name>
    vnc [-w] [<[bind_addr:]port>] <zone_name>
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

S<Dominik Hassler E<lt>hadfl@omnios.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
