package Zadm::Image::base;
use Mojo::Base -base;

use Mojo::Exception;
use Mojo::Home;
use Mojo::File;
use File::Path qw(make_path);
use File::stat;
use Digest::SHA;

my $MAX_AGE = 24 * 60 * 60;

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub { Zadm::Utils->new(log => shift->log) };
has datadir  => sub { Mojo::Home->new->rel_file('../var')->to_string };
has provider => sub { lc ((split /::/, ref shift)[-1]) };
has cache    => sub { my $self = shift; $self->datadir . '/cache/' . $self->provider };
has baseurl  => sub { Mojo::Exception->throw("ERROR: baseurl must be specified in derived class.\n") };
has index    => sub { Mojo::Exception->throw("ERROR: index must be specified in derived class.\n") };
has images   => sub { [] };

# private methods
my $checkChecksum = sub {
    my $self     = shift;
    my $fileName = shift;
    my $digest   = shift;
    my $checksum = shift;

    $self->log->debug("checking checksum of '$fileName'...");
    print "checking image checksum...\n";
    if (Digest::SHA->new($digest)->addfile($self->cache . "/$fileName")->hexdigest
        eq $checksum) {

        return 1;
    }

    return 0;
};

my $getFile = sub {
    my $self     = shift;
    my $fileName = shift;
    my $url      = shift;
    my $opts     = shift // [];

    $self->log->debug("downloading $url...");
    my @cmd = (@$opts, '-o', $self->cache . "/$fileName", $url);

    $self->utils->exec('curl', \@cmd);
};

sub postProcess {
    shift->utils->isVirtual;
}

sub download {
    my $self = shift;
    my $file = shift;
    my $url  = shift;
    my $opts = { @_ };

    # check if cache directory exists
    -d $self->cache || make_path($self->cache)
        or Mojo::Exception->throw("ERROR: cannot create cache directory $self->cache\n");

    $self->log->debug("checking cache for '$file' (provider: '" . $self->provider . "')...");
    my $freshDl = 0;
    -f $self->cache . "/$file" || do {
        $self->log->debug("$file not found in cache...");
        $self->$getFile($file, $url, $opts->{curl});
        $freshDl = 1;
    };

    # check if cache file has a max_age property and redownload if expired
    exists $opts->{max_age} && !$freshDl
        && (time - stat ($self->cache . "/$file")->mtime > $opts->{max_age})
        && $self->$getFile($file, $url, $opts->{curl});

    # check checksum if chksum option is set
    exists $opts->{chksum} && do {
        $self->$checkChecksum($file, $opts->{chksum}->{digest}, $opts->{chksum}->{chksum}) || do {
            # re-download since checksum mismatch
            $self->log->debug("re-downloading '$file' because of checksum mismatch...");
            $self->$getFile($file, $url, $opts->{curl});
            $self->$checkChecksum($file, $opts->{chksum}->{digest}, $opts->{chksum}->{chksum})
                or Mojo::Exception->throw("ERROR: checksum mismatch of file '$file'.\n");
        };
    };

    return $self->cache . "/$file";
}

sub fetchImages {
    my $self  = shift;
    my $force = shift;

    $self->download('index.txt', $self->index, max_age => ($force ? -1 : $MAX_AGE), curl => [ qw(-s) ]);
    $self->images($self->postProcess(Mojo::File->new($self->cache . '/index.txt')->slurp));
}

sub postInstall {}

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
