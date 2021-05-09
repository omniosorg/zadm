package Zadm::VNC::Proxy;
use Mojo::Base -base, -signatures;

use Mojo::Exception;
use Mojo::IOLoop;
use Mojo::Log;
use Zadm::Privilege qw(:CONSTANTS privSet);

# attributes
has log  => sub { Mojo::Log->new(level => 'debug') };
has addr => '127.0.0.1';
has port => 5900;
has sock => sub { Mojo::Exception->throw("ERROR: 'sock' must be specified on instantiation.\n") };

sub start($self) {
    Mojo::IOLoop->next_tick(sub($ioloop) {
        privSet(undef, PRIV_FILE_READ, PRIV_NET_ACCESS, $self->port < 1024 ? PRIV_NET_PRIVADDR : ());
    });

    Mojo::IOLoop->next_tick(sub($ioloop) {
        Mojo::IOLoop->server({ address => $self->addr, port => $self->port } => sub($loop, $stream, $id) {
            $self->log->debug('Client connected from', join ':', $stream->handle->peerhost, $stream->handle->peerport);

            Mojo::IOLoop->next_tick(sub($ioloop) { privSet({ add => 1 }, PRIV_FILE_READ) });

            Mojo::IOLoop->client(path => $self->sock, sub($loop, $err, $unix) {
                return $self->log->warn("WARNING: cannot connect to VNC socket: $err") if $err;
                $unix->on(error => sub($unix, $err) {
                    $self->log->warn("WARNING: connection error occured: $err");
                });

                my $pause = do {
                    my $unpause = sub { $unix->start if $unix; $stream->start };
                    $stream->on(drain => $unpause);
                    $unix->on(drain => $unpause);
                    sub { $unix->stop; $stream->stop };
                };

                $unix->on(read => sub($unix, $bytes) {
                    $pause->();
                    $stream->write($bytes);
                });

                $stream->on(read => sub($stream, $bytes) {
                    $pause->();
                    $unix->write($bytes);
                });

                $stream->on(close => sub {
                    $self->log->debug('Client connection closed');

                    $unix->close;
                    undef $unix;
                });
            });

            Mojo::IOLoop->next_tick(sub($ioloop) { privSet({ remove => 1 }, PRIV_FILE_READ) });
        });
    });

    Mojo::IOLoop->next_tick(sub($ioloop) {
        privSet({ lock => 1 }, PRIV_FILE_READ);
        privSet;
    });

    print 'VNC proxy available at ', $self->addr, ':', $self->port, "\n";

    Mojo::IOLoop->start if !Mojo::IOLoop->is_running;
}


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

2021-05-09 had Initial Version

=cut
