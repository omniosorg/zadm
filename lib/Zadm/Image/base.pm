package Zadm::Image::base;
use Mojo::Base -base, -signatures;

use Mojo::Exception;
use Mojo::Home;
use Mojo::File;
use Digest::SHA;
use Time::Piece;
use Time::Seconds qw(ONE_DAY);
use Zadm::Images;
use Zadm::Utils;

# attributes
has log      => sub { Mojo::Log->new(level => 'debug') };
has utils    => sub($self) { Zadm::Utils->new(log => $self->log) };
has datadir  => sub { Mojo::Home->new->detect(__PACKAGE__)->rel_file('var')->to_string };
has provider => sub($self) { lc ((split /::/, ref $self)[-1]) };
has cache    => sub($self) {
    my $cache = Mojo::File->new($self->datadir, 'cache', $self->provider);
    # check if cache directory exists
    -d $cache || $cache->make_path
        or Mojo::Exception->throw("ERROR: cannot create cache directory $self->cache\n");

    return $cache;
};
has baseurl => sub { Mojo::Exception->throw("ERROR: baseurl must be specified in derived class.\n") };
has index   => sub { Mojo::Exception->throw("ERROR: index must be specified in derived class.\n") };
has idxpath => sub($self) { Mojo::File->new($self->cache, 'index.txt') };
has idxrefr => sub($self) { !-f $self->idxpath || localtime->epoch - ONE_DAY > $self->idxpath->stat->mtime };
has imgs    => sub($self) { -r $self->idxpath ? $self->postProcess($self->idxpath->slurp) : [] };
has images  => sub($self) { Zadm::Images->new(log => $self->log) };

# private methods
my $checkChecksum = sub($self, $file, $digest, $checksum) {
    $self->log->debug(q{checking checksum of '} . $file->basename . q{'...});
    print "checking image checksum...\n";

    return Digest::SHA->new($digest)->addfile($file->to_string)->hexdigest eq $checksum;
};

# public methods
sub postProcess($self) {
    $self->utils->isVirtual;
}

sub download($self, $fileName, $url, %opts) {
    my $file = Mojo::File->new($self->cache, $fileName);
    $self->log->debug("checking cache for '$fileName' (provider: '" . $self->provider . "')...");

    $self->images->curl([{ path => $file, url => $url }], \%opts) if !-f $file;

    return $file if !exists $opts{chksum}
        || $self->$checkChecksum($file, $opts{chksum}->{digest}, $opts{chksum}->{chksum});

    # re-download since checksum mismatch
    $self->log->debug("re-downloading '$fileName' because of checksum mismatch...");
    $self->images->curl([{ path => $file, url => $url }], \%opts);
    $self->$checkChecksum($file, $opts{chksum}->{digest}, $opts{chksum}->{chksum})
        or Mojo::Exception->throw("ERROR: checksum mismatch for file '$fileName'.\n");

    return $file;
}

sub vacuum($self, $ts) {
    for my $f (Mojo::File->new($self->cache)->list->each) {
        next if $f =~ /index\.txt$/ || $f->stat->atime > $ts;

        $self->log->debug("removing '$f' from cache...");
        $f->remove;
    }
}

sub preSetConfig($self, $brand, $cfg, $opts = {}) { return $cfg; }

sub postInstall($self, $brand, $opts = {}) {}

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

S<Dominik Hassler E<lt>hadfl@omnios.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
