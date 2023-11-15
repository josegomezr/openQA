#!/usr/bin/env perl

# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CommandServerNg;
use Mojo::Base 'Mojolicious', 'Mojo::EventEmitter', -signatures;
use Mojo::File ();
use Mojo::JSON ();
use Data::Dumper qw(Dumper);
use Mojo::EventEmitter ();
use Mojo::Promise ();
use Mojo::Transaction::HTTPWithHijack ();
use POSIX ();

my $event_bus = Mojo::EventEmitter->new();
my $ws_clients = {};

my $base_url = Mojo::URL->new("http://127.0.0.1:8080/v1.43");
my $ua = Mojo::UserAgent->new();

has container_tx => undef;
has logger => sub {
    return Mojo::Log->new(color => 1)->context('command-server');
};

my $command_counter = 0;
my $GLOBAL_STATE = {state => 'idle',};
my $event_log = Mojo::File->new('command-server-event-log.json');
my $output_buffer = '';
open(my $output_buffer_writer, "+<", \$output_buffer) or die "Can't open memory file: $!";

sub stop_container {
    my $promise = Mojo::Promise->new();
    my $url = $base_url->clone->path('containers/perl-test/stop');

    $ua->post(
        $url,
        {Host => 'docker'},
        json => {t => 1},
        sub {
            my ($ua, $tx) = @_;

            return $promise->resolve() unless $tx->res->error;

            my $reason = $tx->res->error;
            $reason = $tx->result->json if $tx->res->code;
            $promise->reject($reason);
            # print Mojo::Util::dumper($tx->result->json);
        });

    return $promise;
}

sub delete_container {
    my $promise = Mojo::Promise->new();

    my $url = $base_url->clone->path('containers/perl-test');
    $ua->delete(
        $url,
        {Host => 'docker'},
        json => {force => Mojo::JSON->true},
        sub {
            my ($ua, $tx) = @_;
            return $promise->resolve($tx->result->json) unless $tx->res->error;
            my $reason = $tx->res->error;
            $reason = $tx->result->json if $tx->res->code;
            $promise->reject($reason);
            # print Mojo::Util::dumper($tx->result->json);
        });

    return $promise;
}

# hacks by me
my $is_a_tty = 1;

sub create_container {
    my $promise = Mojo::Promise->new();
    my $url = $base_url->clone->path('containers/create');

    $url->query->param('Name', 'perl-test');

    my $params = {
        Hostname => 'openqa-test',
        Cmd => ['sh'],
        Image => 'registry.opensuse.org/opensuse/leap',
        AttachStdin => Mojo::JSON->true,
        AttachStdout => Mojo::JSON->true,
        AttachStderr => Mojo::JSON->true,
        OpenStdin => Mojo::JSON->true,
        StdinOnce => Mojo::JSON->true,
        ConsoleSize => [24, 80],
        Tty => $is_a_tty ? Mojo::JSON->true : Mojo::JSON->false,
        Env => ["PS1=# "],
        HostConfig => {
            AutoRemove => Mojo::JSON->true,
        },
    };

    $ua->post(
        $url,
        {Host => 'docker'},
        json => $params => sub {
            my ($ua, $tx) = @_;

            my $has_error = $tx->res->error && (!$tx->res->code || $tx->res->code != 404);

            return $promise->resolve($tx->result->json) unless $has_error;

            my $reason = $tx->res->error;
            $reason = $tx->result->json if $tx->res->code;
            $promise->reject($reason);
        });

    return $promise;
}

sub attach_container {
    my ($self, $cid) = @_;
    my $promise = Mojo::Promise->new();

    my $url = $base_url->clone->path("containers/$cid/attach");
    $url->query->param('stream', 1)->param('stdout', 1)->param('stdin', 1)->param('logs', 1)->param('stderr', 1);

    # my $container_tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade'});
    my $container_tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade', Upgrade => 'tcp'});
    # Decorate the transaction with HTTP Hijack implementation.
    $container_tx = Mojo::Transaction::HTTPWithHijack->new($container_tx);
    # Proceed as normal.
    $ua->inactivity_timeout(500);

    handle_container_connection($container_tx);
    $container_tx->on(unexpected => sub{
        say Mojo::Util::dumper('unexpected');
    });

    $container_tx->res->content->once(
        read => sub {
            # say Mojo::Util::dumper('once');
            my ($content, $content_bytes) = @_;
            $promise->resolve($container_tx);
        });

    $container_tx->on(
        error => sub {
            # say Mojo::Util::dumper('error');
            say 'error in the container tx';
            $promise->reject('container-tx-error');
        });

    $ua->start(
        $container_tx,
        sub {
            # say Mojo::Util::dumper('closed');
            say 'SOCKET CLOSED';
            $self->container_tx(undef);
            delete $GLOBAL_STATE->{'cid'};
        });
    $self->container_tx($container_tx);
    return $promise;
}

sub detect_stream_type {
    my ($content_bytes) = @_;

    # Multiplexed output has a frame header with 8 bytes.
    # bytes 1-3 are NUL.

    my ($stream_type, $nul1, $nul2, $nul3) = unpack("CCCC", $content_bytes);
    # safeguard for short strings that could break the assertions below.
    $stream_type //= 255;

    #                           STDIN                STDOUT               STDERR
    # my $looks_like_a_stream = $stream_type == 0 || $stream_type == 1 || $stream_type == 2;
    # my $looks_like_a_stream = (grep { $stream_type == $_ } (0..2)) == 1;
    my $looks_like_a_stream = $stream_type >= 0 && $stream_type <= 2;
    my $padding_bytes_present = defined $nul1 && defined $nul2 && defined $nul3;
    my $padding_bytes_are_zero = (($nul1 // 0) + ($nul2 // 0) + ($nul3 // 0)) == 0;
    my $is_multiplexed_stream = $looks_like_a_stream && $padding_bytes_present && $padding_bytes_are_zero;

    return 'multiplexed' if $is_multiplexed_stream;
    return 'raw';
}

sub normalize_stream_output {
    my ($content_bytes) = @_;
    # my %STREAM_NAMES = ( '0' => 'STDIN', '1' => 'STDOUT', '2' => 'STDERR', );

    my $output = "";
    # if it's a raw TTY, no processing is needed
    if (detect_stream_type($content_bytes) eq 'raw') {
        return $content_bytes;
    }
    # Unpack the stream. See HTTP Transport Hijacking on:
    # - https://docs.docker.com/engine/api/v1.43/#tag/Container/operation/ContainerAttach
    # - https://docs.podman.io/en/latest/_static/api.html#tag/containers/operation/ContainerAttachLibpod
    my @frames = unpack_framed_streams($content_bytes);
    while (@frames) {
        my ($stream, $stream_size, $stream_content) = splice(@frames, 0, 3);
        # say $STREAM_NAMES{$stream}, ": ", $stream_content;
        $output .= $stream_content;
    }

    # Normalize newlines for frontend (output is not a tty raw stream).
    $output =~ s/(?<!\r)\n/\r\n/g;

    return $output;
}

sub handle_container_connection {
    my ($tx) = @_;

    $tx->res->content->unsubscribe('read');
    $tx->res->content->on(
        read => sub {
            my ($content, $content_bytes) = @_;
            # say Mojo::Util::dumper('read', $content_bytes);

            my $output = normalize_stream_output($content_bytes);
            return unless $output;

            local $| = 1;
            print $output_buffer_writer $output;

            $event_bus->emit(
                'feed_update',
                {
                    type => 'terminal-output',
                    line => $output
                });
        });
}

sub start_container {
    my ($cid) = @_;
    my $promise = Mojo::Promise->new();
    $event_log->open('>');
    my $url = $base_url->clone->path("containers/$cid/start");
    return $ua->post(
        $url,
        {Host => 'docker'},
        sub {
            # TODO: handle error.
            $promise->resolve();
        });

    return $promise;
}

sub resize_container {
    my ($cid) = @_;
    my $promise = Mojo::Promise->new();
    my $url = $base_url->clone->path("containers/$cid/resize");
    $url->query->param('h', 24)->param('w', 80);
    $ua->post(
        $url,
        {Host => 'docker'},
        sub {
            # TODO: handle error.
            $promise->resolve();
        });
    return $promise;
}

sub run_container {
    my ($self) = @_;
    my $promise = Mojo::Promise->new();

    # say 'create-container';
    create_container()->then(
        sub {
            my ($container_info) = @_;
            my $cid = $container_info->{Id};

            # TODO: find a cleaner way for this chain.
            $GLOBAL_STATE->{'cid'} = $cid;
            return $self->attach_container($cid);
        })    # now after attaching
      ->then(
        sub {
            my ($tx) = @_;
            return handle_container_connection($tx);
        })    # now start
      ->then(
        sub {
            my $cid = $GLOBAL_STATE->{'cid'};
            return start_container($cid);
        })    # now resize
      ->then(
        sub {
            my $cid = $GLOBAL_STATE->{'cid'};
            return resize_container($cid);
        })    # finish all
      ->then(
        sub {
            $promise->resolve();
            return;
        }
    )->catch(
        sub {
            my ($reason) = @_;
            # say 'finishing! rejected', Mojo::Util::dumper($reason);
            $promise->reject(@_);
            return;
        });

    return $promise;
}


my $FRAME_STRUCTURE = "" . 'C'    # Stream type: 1 Byte
  . 'x[3]'    # Separator: 3 null bytes
  . 'N'    # Length of stream (uint32, 4 bytes)
  . 'X[4]'    # Back-up 4 bytes
  . 'N/a'    # Pull N characters
  ;

sub unpack_framed_streams {
    return unpack("($FRAME_STRUCTURE)*", shift);
}

sub wait_for_needle {
    my ($self, $current_mark) = @_;
    my $promise = Mojo::Promise->new();
    my $timer;
    my $recurring;

    $current_mark = qr/$current_mark/;

    $timer = Mojo::IOLoop->timer(
        10 => sub {
            $promise->reject("timeout: $current_mark", $output_buffer);

            Mojo::IOLoop->remove($timer) if $timer;
            Mojo::IOLoop->remove($recurring) if $recurring;
        });

    $recurring = Mojo::IOLoop->recurring(1 => sub {
        return unless $output_buffer;

        my $found = ($output_buffer =~ $current_mark);
        # clear output buffer
        $output_buffer = '';
        return unless $found;

        $promise->resolve($&, @{^CAPTURE});
        Mojo::IOLoop->remove($timer) if $timer;
        Mojo::IOLoop->remove($recurring) if $recurring;
    });

    return $promise;
}

sub send_command {
    my ($self, $cmd) = @_;
    my $promise = Mojo::Promise->new();

    if(!$cmd){
        return $promise->reject(@_);
    }

    ++$command_counter;
    # Watch out here, markers are unquoted strings in sh to make it easy for
    # perl regexes.
    my $end_mark = "%_${command_counter}_END_\$?_${command_counter}_%";
    
    # ignore the mark after an echo, TTY's will reply everything you type in it.
    my $end_mark_regex = qr{(?<![; echo ])%_${command_counter}_END_(?<exit_code>\d+)_${command_counter}_%};

    $self->type_string("$cmd; echo $end_mark\n")->then(
        sub {
            _notify_state_fn($event_bus, 'wait-for-marker');
            return $self->wait_for_needle($end_mark_regex);
    }, sub {
        $promise->reject(@_);
        return;
    })->then(
        sub {
            my ($exit_status) = @_;
            
            _notify_state_fn($event_bus, 'found_needle', {
                exit_code => $exit_status
            });

            $promise->resolve(@_);
            return;
        }, sub {
            # Forcefully close container socket
            # $tx->closed or $tx->completed will wait until timeout, but:
            # $tx->req->finish(); or $tx->res->finish(); break my mitmproxy...
            if ($self->container_tx) {
                $self->container_tx->res->content->unsubscribe('read');
                $self->container_tx->closed();
                $self->container_tx->completed();
            }

            $promise->reject(@_);
            return;
        })->finally(sub {
        });

    return $promise;
}

sub type_char {
    my ($self, $char) = @_;
    my $promise = Mojo::Promise->new();

    if (!$self->container_tx) {
        return $promise->reject('no-container-conn');
    }
    my $tx = $self->container_tx;

    # $tx->res->content->once(read => sub {
    #     ;
    # });

    $tx->req->content->write($char, sub { $promise->resolve() });
    $tx->resume;

    return $promise;
}

sub type_string {
    my $promise = Mojo::Promise->new();
    my ($self, $string) = @_;

    if (!$self->container_tx) {
        return $promise->reject('no-container-conn');
    }

    my @pieces = ($string);
    # type one char at a time.
    my $wait = 0;
    @pieces = unpack("(a${wait})*", $string) if $wait;

    Mojo::Promise
        ->map({concurrency => 1}, sub { return $self->type_char($_) }, @pieces)
        ->then(sub{ $promise->resolve() }, sub{ $promise->reject() });

    return $promise;
}

sub load_event_log {
    my ($tx) = @_;
    my $fh = $event_log->touch->open('<');

    while (my $line = <$fh>) {
        chomp($line);
        $tx->send($line);
    }
}

sub _notify_state_fn {
    my ($ev_bus, $state, $ctx) = @_;

    $GLOBAL_STATE->{state} = $state;
    my $conn = $GLOBAL_STATE->{connection};
    my $msg = {
        type => 'state-update',
        state => $state,
        datetime => Mojo::Date->new()->to_datetime
    };

    $msg->{context} = $ctx if $ctx;

    $ev_bus->emit('feed_update', $msg);
    $conn->write(Mojo::JSON::encode_json($msg) . "\n") if $conn;
}

sub _configure_current_request {
    my ($conn) = @_;

    # websockets doesn't like this shennanigans...
    return if $conn->tx->is_websocket;
    return if $conn->req->url->path =~ qr{/rpc};

    $GLOBAL_STATE->{connection} = $conn;

    $conn->on(
        finish => sub {
            delete $GLOBAL_STATE->{connection};
        });
}

sub startup {
    my ($self) = @_;

    $self->hook(before_dispatch => sub ($c) { _configure_current_request($c) });

    $self->emit('event');

    $event_bus->on(
        'feed_update',
        sub {
            my ($self, $data) = @_;

            my $msg = Mojo::JSON::encode_json($data);
            # say "$msg\n";

            # Write logs into the file
            {
                my $fh = $event_log->open('>>');
                print $fh "$msg\n";
            }

            # Send updates to connected clients
            foreach my $key (keys %{$ws_clients}) {
                $ws_clients->{$key}->send($msg);
            }
        });

    $self->routes->get(
        '/' => sub {
            my ($c) = @_;
            $c->render('command-handler-ng/dashboard');
        });

    $self->routes->websocket(
        '/feed' => sub {
            my ($tx) = @_;
            $tx->inactivity_timeout(300);
            # say 'ws: connected';
            $ws_clients->{$tx} = $tx;

            $tx->on(
                message => sub ($self, $msg) {
                    if ($msg eq 'load-event-log') {
                        # say 'sending event log';
                        return load_event_log($self);
                    }

                    $self->send("echo: $msg");
                });

            $tx->on(
                finish => sub ($self, $code, $reason) {
                    delete $ws_clients->{$tx} if $ws_clients->{$tx};
                });
        });


    $self->routes->post(
        '/start' => sub {
            my ($c) = @_;
            $c->inactivity_timeout(300);

            _notify_state_fn($event_bus, 'starting');

            $self->run_container()->then(
                sub {
                    _notify_state_fn($event_bus, 'wait-for-command');
                    # return type_string($container_tx, "\r");
                }
            )->catch(
                sub {
                    _notify_state_fn($event_bus, 'error-starting', {ctx => @_});
                }
            )->finally(
                sub {
                    $c->finish();
                });
        });

    $self->routes->post(
        '/run-command' => sub {
            my ($c) = @_;
            my $cmd = $c->param('foo');

            return $c->render(json => {result => 'fail-no-command'}) unless $cmd;
            return $c->render(json => {result => 'fail-no-container'}) unless $self->container_tx;

            $c->inactivity_timeout(0);
            _notify_state_fn($event_bus, 'running-command');

            $self->send_command($cmd)->then(
                sub {
                    my ($json) = @_;
                    _notify_state_fn($event_bus, 'success');
                },
                sub {
                    my ($json) = @_;
                    _notify_state_fn($event_bus, 'expired');
                }
            )->finally(
                sub {
                    _notify_state_fn($event_bus, 'started');
                    $c->finish();
                });
        });

    $self->routes->post(
        '/type' => sub {
            my ($c) = @_;
            my $string = $c->param('foo');

            # return $c->render(json => {result => 'fail-no-str'}) unless $string;
            return $c->render(json => {result => 'fail-no-container'}) unless $self->container_tx;

            $c->inactivity_timeout(0);
            _notify_state_fn($event_bus, 'typing');

            $self->type_string($string)->then(
                sub {
                    my ($json) = @_;
                    _notify_state_fn($event_bus, 'success', $json);
                },
                sub {
                    my ($json) = @_;
                    _notify_state_fn($event_bus, 'failed', $json);
                }
            )->finally(
                sub {
                    _notify_state_fn($event_bus, 'wait-for-command');
                    $c->finish();
                });
        });

    $self->routes->post(
        '/stop' => sub {
            my ($c) = @_;
            $c->inactivity_timeout(300);
            _notify_state_fn($event_bus, 'stopping');

            stop_container()->then(
                sub {
                    _notify_state_fn($event_bus, 'deleting');
                    return delete_container();
                }
            )->then(
                sub {
                    _notify_state_fn($event_bus, 'stopped');
                    $c->render(text => 'stopped container');
                },
                sub {
                    my ($reason) = @_;
                    _notify_state_fn($event_bus, 'error-deleting');
                }
            )->finally(
                sub {
                    _notify_state_fn($event_bus, 'idle');
                    $c->finish();
                });
        });

    # Some controllers are shared between openQA micro services
    my $r = $self->routes->namespaces(['OpenQA::CommandServerNg::Controller']);

    $self->routes->post('/rpc')->to('RPC#process');
}

1;
