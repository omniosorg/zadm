# taken from https://github.com/jberger/Mojo-Websockify
package Zadm::VNC::NoVNC;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::Home;
use Mojo::IOLoop;
use Zadm::Privilege qw(:CONSTANTS privSet);

# constants
my $NOVNC = Mojo::Home->new->detect(__PACKAGE__)->rel_file('novnc')->to_string;

sub startup($self) {
    my $r = $self->routes;

    $self->hook(before_server_start => sub($server, $app) {
        privSet(undef, PRIV_FILE_READ, PRIV_NET_ACCESS, $self->{port} < 1024 ? PRIV_NET_PRIVADDR : ());
    });
    $self->hook(before_dispatch => sub($c) {
        privSet({ add => 1 }, PRIV_FILE_READ);
    });
    $self->hook(after_dispatch => sub($c) {
        privSet({ remove => 1 }, PRIV_FILE_READ);
    });
    Mojo::IOLoop->next_tick(sub($ioloop) { privSet({ lock => 1 }, PRIV_FILE_READ); privSet });

    my $novnc = $self->{novnc} || $NOVNC;
    Mojo::Exception->throw("noVNC not found under '$novnc'\n")
        if !-r Mojo::File->new($novnc, 'vnc.html');

    unshift @{$self->static->paths}, $novnc;

    $r->websocket('/websockify' => sub($c) {
        $c->render_later->on(finish => sub { $c->app->log->info('websocket closing') });

        my $tx = $c->tx;
        $tx->with_protocols('binary');

        Mojo::IOLoop->next_tick(sub($ioloop) { privSet({ add => 1 }, PRIV_FILE_READ) });
        Mojo::IOLoop->client(path => $self->{sock}, sub($loop, $err, $unix) {
            return $tx->finish(4500, "UNIX socket connection error: $err") if $err;
            $unix->on(error => sub($unix, $err) { $tx->finish(4500, "UNIX socket error: $err") });

            my $pause = do {
                my $ws_stream = Mojo::IOLoop->stream($tx->connection);
                my $unpause = sub { $unix->start if $unix; $ws_stream->start };
                $ws_stream->on(drain => $unpause);
                $unix->on(drain => $unpause);
                sub { $unix->stop; $ws_stream->stop };
            };

            $unix->on(read => sub($unix, $bytes) {
                $pause->();
                $tx->send({binary => $bytes});
            });

            $tx->on(binary => sub($tx, $bytes) {
                $pause->();
                $unix->write($bytes);
            });

            $tx->on(finish => sub {
                $unix->close;
                undef $unix;
                undef $tx;
            });
        });
        Mojo::IOLoop->next_tick(sub($ioloop) { privSet({ remove => 1 }, PRIV_FILE_READ) });
    });

    $r->get('/' => sub($c) { $c->reply->static('vnc.html') });
}

1;

