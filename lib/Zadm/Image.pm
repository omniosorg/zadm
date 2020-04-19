package Zadm::Image;
use Mojo::Base -base;

use Mojo::Home;
use Mojo::Exception;
use File::Spec;

my $MODPREFIX = 'Zadm::Image';

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub { Zadm::Utils->new(log => shift->log) };
has datadir  => sub { Mojo::Home->new->rel_file('../var')->to_string };
has images   => sub { {} };

has provider => sub {
    my $self = shift;

    my %provider;
    for my $path (@INC) {
        my @mDirs = split /::/, $MODPREFIX;
        my $fPath = File::Spec->catdir($path, @mDirs, '*.pm');
        for my $file (sort glob $fPath) {
            my ($volume, $modulePath, $modName) = File::Spec->splitpath($file);
            $modName =~ s/\.pm$//;
            next if $modName eq 'base';

            my $module = $MODPREFIX . '::' . $modName;
            my $mod = do {
                eval "require $module";
                $module->new(log => $self->log, utils => $self->utils, datadir => $self->datadir);
            };
            $provider{$mod->provider} = $mod if $mod;
        }
    }

    return \%provider;

};

sub getImage {
    my $self  = shift;
    my $uuid  = shift;
    my $brand = shift;

    $self->fetchImages;

    my @imgs;
    my $provider;
    for my $prov (keys %{$self->images}) {
        if (my @provimgs = grep { $_->{brand} eq $brand && $_->{uuid} =~ /$uuid/ } @{$self->images->{$prov}}) {
            push @imgs, @provimgs;
            $provider = $prov;
        }
    }

    @imgs < 1 and Mojo::Exception->throw("ERROR: $brand image UUID containing '$uuid' not found.\n");
    @imgs > 1 and Mojo::Exception->throw("ERROR: more than one $brand image uuid contains '$uuid'.\n");

    my $img = $imgs[0];
    $self->log->info("found $brand image '$img->{name}' from provider '$provider'");

    # TODO: need to add filename + extension handling, for now just assume everything is tar.gz
    $img->{_file} = $self->provider->{$provider}->download($img->{uuid} . '.tar.gz', $img->{img}, chksum => $img->{chksum});

    # return the whole structure including all the metadata
    return $img;
}

sub fetchImages {
    my $self  = shift;
    my $force = shift;

    do {
        $self->provider->{$_}->fetchImages($force);
        $self->images->{$_} = $self->provider->{$_}->images;
    } for keys %{$self->provider};
}

sub dump {
    my $self = shift;

    $self->fetchImages;

    printf "%-10s%-10s%-8s%-36s%-16s%s\n", qw(UUID PROVIDER BRAND NAME VERSION DESCRIPTION);
    for my $prov (sort keys %{$self->images}) {
        printf "%-10s%-10s%-8s%-36s%-16s%s\n", substr ($_->{uuid}, length ($_->{uuid}) - 8), $prov, $_->{brand}, $_->{name}, $_->{vers}, $_->{desc}
            for sort { $a->{name} cmp $b->{name} } @{$self->images->{$prov}};
    }
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
