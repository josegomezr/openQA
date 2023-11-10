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
my $tx;

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
      return $promise;
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
      return $promise;
    }

    $promise->resolve();
    # print Mojo::Util::dumper($tx->result->json);
  });

  return $promise;
}

sub start_container {
  my $promise = Mojo::Promise->new();

  my $url = $base_url->clone->path('containers/create');
  my $resp;
  
  $url->query->param('Name', 'perl-test');

  my $params = {
      Hostname => 'openqa-test',
      # Cmd => ['sleep', '3600'],
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

  $resp = $ua->post($url, {Host => 'docker'}, json => $params);

  if ($resp->res->error && (!$resp->res->code || $resp->res->code != 404)) {
    my $reason = $resp->res->error;
    $reason = $resp->result->json if $resp->res->code;
    $promise->reject($reason);
    return $promise;
  }
  # print Mojo::Util::dumper($resp->result->json);

  my $cid = $resp->result->json->{Id};

  $url = $base_url->clone->path("containers/$cid/attach");
  $url->query
      ->param('stream', 1)
      ->param('stdout', 1)
      ->param('stdin', 1)
      ->param('logs', 1)
      ->param('stderr', 1)
      ;

  $tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade'});
  $ua->inactivity_timeout(500);

  my $timer;

  $tx->res->content->unsubscribe('read');
  $tx->res->content->on(read => sub {
      my ($content, $content_bytes) = @_;
      $promise->resolve();

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

      if((0,0,0) == unpack("xCCC", $content_bytes)){
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

  $ua->start($tx, sub {
    say 'SOCKET CLOSED';
    $tx = undef;
  });

  $url = $base_url->clone->path("containers/$cid/start");
  $resp = $ua->post($url, {Host => 'docker'});

  $url = $base_url->clone->path("containers/$cid/resize");
  $url->query
      ->param('h', 24)
      ->param('w', 80)
      ;
  $resp = $ua->post($url, {Host => 'docker'});
  
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
        $promise->reject();
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
      $promise->reject();
    }

    $tx->req->content->write($string,  sub {
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

  # $event_bus->on('command_stdout', sub {
  #   my ($e, $line) = @_;

  #   $c->write(Mojo::JSON::encode_json({
  #     stdout => $line
  #     }) . "\n" );
  # });

  # $event_bus->on('command_stderr', sub {
  #   my ($e, $line) = @_;
  #   $c->write(Mojo::JSON::encode_json({
  #     stdout => $line
  #     }) . "\n" );
  # });

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
    
    $event_bus->emit('feed_update', {
      type => 'state-update',
      state => $GLOBAL_STATE->{state},
      datetime => Mojo::Date->new()->to_datetime
    });

    $c->write(
      Mojo::JSON::encode_json({
        state => $GLOBAL_STATE->{state}
      }) . "\n"
    );

    start_container()
      ->then(sub {
        type_string($tx, "\r");
        $GLOBAL_STATE->{state} = 'wait-for-command';

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => $GLOBAL_STATE->{state},
          datetime => Mojo::Date->new()->to_datetime
        });

        $c->write(
          Mojo::JSON::encode_json({
            state => $GLOBAL_STATE->{state}
          }) . "\n"
        );
      }, sub {
        my ($reason) = @_;

        $c->write(
          Mojo::JSON::encode_json({
            state => 'error-starting',
            ctx => $reason
          }) . "\n"
        );

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => 'error-starting',
          datetime => Mojo::Date->new()->to_datetime,
          ctx => $reason
        });
      })
      ->finally(sub {
        $c->finish();
      });
  });

  $self->routes->post('/run-command' => sub {
    my ($c) = @_;
    my $cmd = $c->param('foo');
    if (!$cmd){
      return $c->render(json => {
        result => 'fail-no-command'
      });
    }

    if (!$tx){
      return $c->render(json => {
        result => 'fail-no-container'
      });
    }

    $c->inactivity_timeout(0);
    $GLOBAL_STATE->{state} = 'running-command';
    sleep 1;
  

    send_command($tx, $cmd)
      ->then(sub {
        my ($json) = @_;
        
        $c->write(
          Mojo::JSON::encode_json({
            result => 'success',
            response => $json
          }) . "\n"
        );
      }, sub {
        my ($json) = @_;

        $c->write(
          Mojo::JSON::encode_json({
            result => 'expired',
            response => $json
          }) . "\n"
        );
      })
      ->finally(sub {
        $event_bus->unsubscribe('command_expired');
        $event_bus->unsubscribe('found_needle');
        $GLOBAL_STATE->{state} = 'started';
        $c->finish();
      });
  });

  $self->routes->post('/type' => sub {
    my ($c) = @_;
    my $string = $c->param('foo');
    if (!$string){
      return $c->render(json => {
        result => 'fail-no-str'
      });
    }

    if (!$tx){
      return $c->render(json => {
        result => 'fail-no-container'
      });
    }

    $c->inactivity_timeout(0);
    $GLOBAL_STATE->{state} = 'typing';

    $event_bus->emit('feed_update', {
      type => 'state-update',
      state => $GLOBAL_STATE->{state},
      datetime => Mojo::Date->new()->to_datetime
    });
    
    $c->write(
      Mojo::JSON::encode_json({
        state => $GLOBAL_STATE->{state}
      }) . "\n"
    );

    type_string($tx, $string)
      ->then(sub {
        my ($json) = @_;

        $c->write(
          Mojo::JSON::encode_json({
            result => 'success',
            response => $json
          }) . "\n"
        );
      }, sub {
        my ($json) = @_;

        $c->write(
          Mojo::JSON::encode_json({
            result => 'failed',
            response => $json
          }) . "\n"
        );
      })
      ->finally(sub {
        $GLOBAL_STATE->{state} = 'wait-for-command';
        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => $GLOBAL_STATE->{state},
          datetime => Mojo::Date->new()->to_datetime
        });
        
        $c->write(
          Mojo::JSON::encode_json({
            state => $GLOBAL_STATE->{state}
          }) . "\n"
        );
        $c->finish();
      });
  });

  $self->routes->post('/stop' => sub {
    my ($c) = @_;
    $c->inactivity_timeout(300);
    
    $GLOBAL_STATE->{state} = 'stopping';

    $event_bus->emit('feed_update', {
      type => 'state-update',
      state => $GLOBAL_STATE->{state},
      datetime => Mojo::Date->new()->to_datetime
    });

    $c->write(
      Mojo::JSON::encode_json({
        state => $GLOBAL_STATE->{state}
      }) . "\n"
    );

    stop_container()
      ->then(sub {
        $GLOBAL_STATE->{state} = 'deleting';

        $c->write(
          Mojo::JSON::encode_json({
            state => $GLOBAL_STATE->{state}
          }) . "\n"
        );

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => $GLOBAL_STATE->{state},
          datetime => Mojo::Date->new()->to_datetime
        });

        return delete_container();
      })->then(sub {
        $GLOBAL_STATE->{state} = 'stopped';

        $c->write(
          Mojo::JSON::encode_json({
            state => $GLOBAL_STATE->{state}
          }) . "\n"
        );

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => $GLOBAL_STATE->{state},
          datetime => Mojo::Date->new()->to_datetime
        });

        $c->render(text => 'stopped container');
      }, sub {
        my ($reason) = @_;

        $c->write(
          Mojo::JSON::encode_json({
            state => 'error-deleting',
            ctx => $reason
          }) . "\n"
        );

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => 'error-deleting',
          datetime => Mojo::Date->new()->to_datetime,
          ctx => $reason
        });

      })->finally(sub {
        $GLOBAL_STATE->{state} = 'idle';

        $c->write(
          Mojo::JSON::encode_json({
            state => $GLOBAL_STATE->{state}
          }) . "\n"
        );

        $event_bus->emit('feed_update', {
          type => 'state-update',
          state => $GLOBAL_STATE->{state},
          datetime => Mojo::Date->new()->to_datetime
        });

        $c->finish();
      });
  });
}

1;
