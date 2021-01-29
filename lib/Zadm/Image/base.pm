package Zadm::Image::base;
use Mojo::Base -base;

use Mojo::Exception;
use Mojo::Home;
use Mojo::File;
use File::Path qw(make_path);
use File::stat;
use Digest::SHA;
use Time::Piece;
use Time::Seconds qw(ONE_DAY);

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub { Zadm::Utils->new(log => shift->log) };
has datadir  => sub { Mojo::Home->new->detect(__PACKAGE__)->rel_file('var')->to_string };
has provider => sub { lc ((split /::/, ref shift)[-1]) };
has cache    => sub { my $self = shift; $self->datadir . '/cache/' . $self->provider };
has baseurl  => sub { Mojo::Exception->throw("ERROR: baseurl must be specified in derived class.\n") };
has index    => sub { Mojo::Exception->throw("ERROR: index must be specified in derived class.\n") };
has images   => sub { my $self = shift; $self->postProcess(Mojo::File->new($self->cache, 'index.txt')->slurp) };

# private methods
my $checkChecksum = sub {
    my $self     = shift;
    my $file     = shift;
    my $digest   = shift;
    my $checksum = shift;

    $self->log->debug(q{checking checksum of '} . $file->basename . q{'...});
    print "checking image checksum...\n";

    return Digest::SHA->new($digest)->addfile($file->to_string)->hexdigest eq $checksum;
};

my $getFile = sub {
    my $self = shift;
    my $file = shift;
    my $url  = shift;
    my $opts = shift // [];

    $self->log->debug("downloading $url...");
    $self->utils->curl($file, $url, $opts);
};

sub postProcess {
    shift->utils->isVirtual;
}

sub download {
    my $self     = shift;
    my $fileName = shift;
    my $url      = shift;
    my $opts     = { @_ };

    # check if cache directory exists
    -d $self->cache || make_path($self->cache)
        or Mojo::Exception->throw("ERROR: cannot create cache directory $self->cache\n");

    my $file = Mojo::File->new($self->cache, $fileName);
    $self->log->debug("checking cache for '$fileName' (provider: '" . $self->provider . "')...");

    $self->$getFile($file, $url, $opts->{curl}) if !-f $file
        || (exists $opts->{max_age} && localtime->epoch - $opts->{max_age} > $file->stat->mtime);

    return $file if !exists $opts->{chksum}
        || $self->$checkChecksum($file, $opts->{chksum}->{digest}, $opts->{chksum}->{chksum});

    # re-download since checksum mismatch
    $self->log->debug("re-downloading '$fileName' because of checksum mismatch...");
    $self->$getFile($file, $url, $opts->{curl});
    $self->$checkChecksum($file, $opts->{chksum}->{digest}, $opts->{chksum}->{chksum})
        or Mojo::Exception->throw("ERROR: checksum mismatch for file '$fileName'.\n");

    return $file;
}

sub fetchImages {
    my $self  = shift;
    my $force = shift;

    $self->download('index.txt', $self->index, max_age => ($force ? -1 : ONE_DAY), curl => [ qw(-s) ]);
}

sub vacuum {
    my $self = shift;
    my $ts   = shift;

    for my $f (Mojo::File->new($self->cache)->list->each) {
        next if $f =~ /index\.txt$/ || $f->stat->atime > $ts;

        $self->log->debug("removing '$f' from cache...");
        $f->remove;
    }
}

sub postInstall {}

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

S<Dominik Hassler E<lt>hadfl@omniosce.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
