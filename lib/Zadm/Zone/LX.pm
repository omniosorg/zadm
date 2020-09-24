package Zadm::Zone::LX;
use Mojo::Base 'Zadm::Zone::base';

has options => sub {
    return {
        %{shift->SUPER::options},
        create  => {
            image => {
                getopt => 'image|i=s',
                mand   => 1,
            },
        },
        install => {
            image => {
                getopt => 'image|i=s',
                mand   => 1,
            },
        },
    }
};

# TODO: we need a mechanism to override kernel-version if provided by the image metadata
# but it's too late here since we already configured the zone and are about to install
sub install {
    my $self = shift;

    my $img = $self->zones->image->getImage($self->opts->{image}, $self->brand);

    $img->{_file} && -r $img->{_file} || do {
        $self->log->warn('WARNING: no valid image path given. skipping install');
        return;
    };
    $self->SUPER::install($img->{_instopt} // '-t', $img->{_file});
}

1;

__END__

=head1 SYNOPSIS

B<zadm> I<command> [I<options...>]

where 'command' is one of the following:

    create -b <brand> -i <image_uuid|image_path_or_uri> [-t <template_path>] <zone_name>
    delete <zone_name>
    edit <zone_name>
    set <zone_name> <property=value>
    install -i <image_uuid|image_path_or_uri> [-f] <zone_name>
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
