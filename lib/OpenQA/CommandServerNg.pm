#!/usr/bin/env perl

# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CommandServerNg;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::File ();
use Mojo::JSON ();
use Mojo::EventEmitter ();
use Mojo::Promise;
use POSIX ();

my $event_bus = Mojo::EventEmitter->new();
my $ws_clients = {};

my %STREAM_NAMES = (
    '0' => 'STDIN',
    '1' => 'STDOUT',
    '2' => 'STDERR',
);

my $base_url = Mojo::URL->new("http://127.0.0.1:8080/v1.43");
my $ua = Mojo::UserAgent->new();
my $container_tx;

my $command_counter = 0;
my $current_cmd;
my $current_mark;

my $GLOBAL_STATE = {
  state => 'idle',
};

sub stop_container {
  my $promise = Mojo::Promise->new();
  my $url = $base_url->clone->path('containers/perl-test/stop');

  $ua->post($url, {Host => 'docker'}, json => { t => 1 }, sub {
    my ($ua, $tx) = @_;

    if ($tx->res->error) {
      my $reason = $tx->res->error;
      $reason = $tx->result->json if $tx->res->code;
      $promise->reject($reason);
      return;
    }

    $promise->resolve();
    # print Mojo::Util::dumper($tx->result->json);
  });

  return $promise;
}

sub delete_container {
  my $promise = Mojo::Promise->new();

  my $url = $base_url->clone->path('containers/perl-test');
  $ua->delete($url, {Host => 'docker'}, json => { force => Mojo::JSON->true }, sub {
    my ($ua, $tx) = @_;

    if ($tx->res->error) {
      my $reason = $tx->res->error;
      $reason = $tx->result->json if $tx->res->code;
      $promise->reject($reason);
      return;
    }

    $promise->resolve();
    # print Mojo::Util::dumper($tx->result->json);
  });

  return $promise;
}

sub create_container {
  my $promise = Mojo::Promise->new();
  my $url = $base_url->clone->path('containers/create');

  $url->query
    ->param('Name', 'perl-test');

  my $params = {
      Hostname => 'openqa-test',
      Cmd => ['sh'],
      Image => 'registry.opensuse.org/opensuse/leap',
      AttachStdin => Mojo::JSON->true,
      AttachStdout => Mojo::JSON->true,
      AttachStderr => Mojo::JSON->true,
      OpenStdin => Mojo::JSON->true,
      StdinOnce => Mojo::JSON->true,
      ConsoleSize => [24,80],
      Tty => Mojo::JSON->true,
      HostConfig => {
        AutoRemove => Mojo::JSON->true,
      },
  };

  $ua->post($url, {Host => 'docker'}, json => $params => sub {
    my ($ua, $tx) = @_;

    if ($tx->res->error && (!$tx->res->code || $tx->res->code != 404)) {
      my $reason = $tx->res->error;
      $reason = $tx->result->json if $tx->res->code;
      $promise->reject($reason);
      return;
    }

    $promise->resolve($tx->result->json);
  });

  return $promise;
}

sub attach_container {
  my ($cid) = @_;
  my $promise = Mojo::Promise->new();

  my $url = $base_url->clone->path("containers/$cid/attach");
  $url->query
      ->param('stream', 1)
      ->param('stdout', 1)
      ->param('stdin', 1)
      ->param('logs', 1)
      ->param('stderr', 1)
      ;

  $container_tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade'});
  $ua->inactivity_timeout(500);

  $container_tx->res->content->unsubscribe('read');
  $container_tx->res->content->once(read => sub {
      my ($content, $content_bytes) = @_;
      $promise->resolve($container_tx);
  });

  $container_tx->on(error => sub {
    say 'error in the container tx';
    $promise->reject('container-tx-error');
  });

  $ua->start($container_tx, sub {
    say 'SOCKET CLOSED';
    $container_tx = undef;
    delete $GLOBAL_STATE->{'cid'};
  });

  return $promise;
}

sub handle_container_connection {
  my ($tx) = @_;

  my $timer;

  $tx->res->content->unsubscribe('read');
  $tx->res->content->on(read => sub {
    my ($content, $content_bytes) = @_;

    if ($GLOBAL_STATE->{state} eq 'wait-for-marker') {
      if($timer){
        # say 'renewing timer';
        Mojo::IOLoop->remove($timer);
      }

      # say 'adding timer';
      $timer = Mojo::IOLoop->timer(5 => sub {
        # say 'abort command execution';
        $tx->emit('command_expired');
        $tx->completed;
      });
    }

    return unless $content_bytes;

    my $found = 0;
    # Multiplexed output has a frame header with 8 bytes.
    # bytes 1-3 are NUL.

    my ($stream_type, $nul1,$nul2,$nul3) = unpack("CCCC", $content_bytes);
    $stream_type //= 255;

    #                         STDIN                   STDOUT                  STDERR
    my $looks_like_a_stream = $stream_type == 0 || $stream_type == 1 || $stream_type == 2;
    my $padding_bytes_present = defined $nul1 && defined $nul2 && defined $nul3;
    my $padding_bytes_are_zero = ($nul1//0)+($nul2//0)+($nul3//0);

    my $is_multiplexed = $looks_like_a_stream && $padding_bytes_present && $padding_bytes_are_zero;

    if($is_multiplexed){
      say 'Multiplexed output';
      my @frames = unpack_framed_streams($content_bytes);
      while (@frames){
        my ($stream_type, $stream_size, $stream_content) = splice(@frames, 0, 3);

        say $STREAM_NAMES{$stream_type}, ": ", $stream_content;

        $event_bus->emit('feed_update', {
          type => 'terminal-output',
          line => "$stream_content\n"
        });

        $event_bus->emit('command_stdout', $stream_content) if $STREAM_NAMES{$stream_type} eq 'STDOUT';
        $event_bus->emit('command_stderr', $stream_content) if $STREAM_NAMES{$stream_type} eq 'STDERR';

        continue unless $current_mark;

        my $mark = $current_mark;
        if($stream_content =~ qr{$mark}) {
          $current_mark = undef;
          $event_bus->emit('found_needle');

          if($timer){
            # say 'clearing timer';
            Mojo::IOLoop->remove($timer);
          }
          # say 'Finished command';
          $GLOBAL_STATE->{state} = 'wait-for-command';
        }
      }
    }else{
      $event_bus->emit('feed_update', {
        type => 'terminal-output',
        line => $content_bytes
      });

      return unless $current_mark;
      my $mark = $current_mark;

      if($content_bytes =~ qr{$mark}) {
        $current_mark = undef;
        $event_bus->emit('found_needle');

        if($timer){
          # say 'clearing timer';
          Mojo::IOLoop->remove($timer);
        }
        # say 'Finished command';
        $GLOBAL_STATE->{state} = 'wait-for-command';
      }
    }
  });
}

sub start_container {
  my ($cid) = @_;
  my $promise = Mojo::Promise->new();
  my $url = $base_url->clone->path("containers/$cid/start");
  return $ua->post($url, {Host => 'docker'}, sub {
    # TODO: handle error.
    $promise->resolve();
  });

  return $promise;
}

sub resize_container {
  my ($cid) = @_;
  my $promise = Mojo::Promise->new();
  my $url = $base_url->clone->path("containers/$cid/resize");
  $url->query
      ->param('h', 24)
      ->param('w', 80)
      ;
  $ua->post($url, {Host => 'docker'}, sub {
    # TODO: handle error.
    $promise->resolve();
  });
  return $promise;
}

sub run_container {
  my $promise = Mojo::Promise->new();

  say 'create-container';
  create_container()
    ->then(sub {
      my ($container_info) = @_;
      my $cid = $container_info->{Id};

      # TODO: find a cleaner way for this chain.
      $GLOBAL_STATE->{'cid'} = $cid;
      return attach_container($cid);
    }) # now after attaching
    ->then(sub {
      my ($tx) = @_;
      return handle_container_connection($tx);
    }) # now start
    ->then(sub {
      my $cid = $GLOBAL_STATE->{'cid'};
      return start_container($cid);
    }) # now resize
    ->then(sub {
      my $cid = $GLOBAL_STATE->{'cid'};
      return resize_container($cid);
    }) # finish all
    ->then(sub {
      $promise->resolve();
      return;
    })->catch(sub {
      my ($reason) = @_;
      say 'finishing! rejected', Mojo::Util::dumper($reason);
      $promise->reject('error-running');
      return;
    });
  
  return $promise;
}


my $FRAME_STRUCTURE = ""
    . 'C' # Stream type: 1 Byte
    . 'x[3]' # Separator: 3 null bytes 
    . 'N' # Length of stream (uint32, 4 bytes)
    . 'X[4]' # Back-up 4 bytes
    . 'N/a' # Pull N characters
    ;

sub unpack_framed_streams {
  return unpack("($FRAME_STRUCTURE)*", shift);
}

sub send_command {
    my $promise = Mojo::Promise->new();
    ++$command_counter;
    my ($tx, $cmd) = @_;
    # Write the body directly
    my $start_mark = "START_MARKER_$command_counter";
    my $end_mark = "END_MARKER_$command_counter";

    $tx->req->content->write("echo $start_mark; $cmd;echo $end_mark;\n",  sub {
      $GLOBAL_STATE->{state} = 'wait-for-marker';

      $current_cmd = $cmd;
      $current_mark = $end_mark;

      $event_bus->once(found_needle => sub {
        $promise->resolve();
      });

      $event_bus->once(command_expired => sub {
        $promise->reject('command-expired');
      });
    });

    # Flush
    $tx->resume;
    return $promise;
}

sub type_string {
    my $promise = Mojo::Promise->new();
    my ($tx, $string) = @_;

    if (!$tx) {
      $promise->reject('no-container-conn');
    }

    $tx->req->content->write("$string",  sub {
      $promise->resolve();
    });

    # Flush
    $tx->resume;
    return $promise;
}

my $event_log = Mojo::File->new('command-server-event-log.json');

sub load_event_log {
  my ($tx) = @_;
  my $fh = $event_log->touch->open('<');
  
  while( my $line = <$fh>)  {   
    chomp($line);
    $tx->send($line);
  }
}

sub _notify_state_fn {
  my ($ev_bus, $conn, $ctx) = @_;

  my $msg = {
    type => 'state-update',
    state => $GLOBAL_STATE->{state},
    datetime => Mojo::Date->new()->to_datetime
  };

  $msg->{context} = $ctx if $ctx;

  $event_bus->emit('feed_update', $msg);
  $conn->write(Mojo::JSON::encode_json($msg) . "\n");
}

sub startup {
	my ($self) = @_;

  $event_bus->on('feed_update', sub {
    my ($self, $data) = @_;

    my $msg = Mojo::JSON::encode_json($data);
    say "$msg\n";

    {
      my $fh = $event_log->open('>>');
      print $fh "$msg\n";
    }

    foreach my $key (keys %{ $ws_clients }) {
      $ws_clients->{$key}->send($msg);
    }
  });

  $self->routes->websocket('/feed' => sub {
    my ($tx) = @_;
    $ws_clients->{$tx} = $tx;

    $tx->on(message => sub ($self, $msg) {
      if ($msg eq 'load-event-log') {
        load_event_log($self);
        return;
      }
      $self->send("echo: $msg");
    });

    $tx->on(finish => sub ($self, $code, $reason) {
      delete $ws_clients->{$tx} if $ws_clients->{$tx};
    });
  });

  $self->routes->get('/' => sub {
    my ($c) = @_;
    $c->render('command-handler-ng/dashboard');
  });

  $self->routes->post('/start' => sub {
    my ($c) = @_;
    $c->inactivity_timeout(300);
    $GLOBAL_STATE->{state} = 'starting';

    _notify_state_fn($event_bus, $c);

    say '>>>run container';
    run_container()
      ->then(sub {
        say '>>>success';
        $GLOBAL_STATE->{state} = 'wait-for-command';
        _notify_state_fn($event_bus, $c);
        $event_log->open('>');
        return type_string($container_tx, "\r");
      })->catch(sub {
        say '<<< fail';
        $GLOBAL_STATE->{state} = 'error-starting';
        _notify_state_fn($event_bus, $c, {ctx => @_});
      })
      ->finally(sub {
        say '<<< close';
        $c->finish();
      });
  });

  $self->routes->post('/run-command' => sub {
    my ($c) = @_;
    my $cmd = $c->param('foo');
    
    return $c->render(json => { result => 'fail-no-command' }) unless $cmd;
    return $c->render(json => { result => 'fail-no-container' }) unless $container_tx;

    $c->inactivity_timeout(0);
    $GLOBAL_STATE->{state} = 'running-command';
    _notify_state_fn($event_bus, $c);

    send_command($container_tx, $cmd)
      ->then(sub {
        my ($json) = @_;
        
        $GLOBAL_STATE->{state} = 'success';
        _notify_state_fn($event_bus, $c);
      }, sub {
        my ($json) = @_;

        $GLOBAL_STATE->{state} = 'expired';
        _notify_state_fn($event_bus, $c);
      })
      ->finally(sub {
        $GLOBAL_STATE->{state} = 'started';
        _notify_state_fn($event_bus, $c);

        $c->finish();
      });
  });

  $self->routes->post('/type' => sub {
    my ($c) = @_;
    my $string = $c->param('foo');

    return $c->render(json => { result => 'fail-no-str' }) unless $string;
    return $c->render(json => { result => 'fail-no-container' }) unless $container_tx;

    $c->inactivity_timeout(0);
    $GLOBAL_STATE->{state} = 'typing';

    _notify_state_fn($event_bus, $c);

    type_string($container_tx, $string)
      ->then(sub {
        my ($json) = @_;

        $GLOBAL_STATE->{state} = 'success';
        _notify_state_fn($event_bus, $c, $json);
      }, sub {
        my ($json) = @_;

        $GLOBAL_STATE->{state} = 'failed';
        _notify_state_fn($event_bus, $c, $json);
      })
      ->finally(sub {
        $GLOBAL_STATE->{state} = 'wait-for-command';
        _notify_state_fn($event_bus, $c);

        $c->finish();
      });
  });

  $self->routes->post('/stop' => sub {
    my ($c) = @_;
    $c->inactivity_timeout(300);
    
    $GLOBAL_STATE->{state} = 'stopping';
    _notify_state_fn($event_bus, $c);

    stop_container()
      ->then(sub {
        $GLOBAL_STATE->{state} = 'deleting';

        _notify_state_fn($event_bus, $c);

        return delete_container();
      })->then(sub {
        $GLOBAL_STATE->{state} = 'stopped';
        _notify_state_fn($event_bus, $c);

        $c->render(text => 'stopped container');
      }, sub {
        my ($reason) = @_;

        $GLOBAL_STATE->{state} = 'error-deleting';
        _notify_state_fn($event_bus, $c);

      })->finally(sub {
        $GLOBAL_STATE->{state} = 'idle';
        _notify_state_fn($event_bus, $c);

        $c->finish();
      });
  });
}

1;
