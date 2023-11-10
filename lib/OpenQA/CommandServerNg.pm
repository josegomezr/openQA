#!/usr/bin/env perl

# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CommandServerNg;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::Promise;

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
  state => 'stopped',
};

sub stop_container {
  my $promise = Mojo::Promise->new();

  my $url = $base_url->clone->path('containers/perl-test/stop');

  $ua->post($url, {Host => 'docker'}, json => { t => 1}, sub {
    my ($ua, $tx) = @_;

    if ($tx->res->error) {
	    # print Mojo::Util::dumper($tx);
			$promise->reject();
			return;
    }

    $promise->resolve();
    print Mojo::Util::dumper($tx->result->json);
  });

  return $promise;
}

sub delete_container {
  my $promise = Mojo::Promise->new();

  my $url = $base_url->clone->path('containers/perl-test');
  $ua->delete($url, {Host => 'docker'}, json => { force => Mojo::JSON->true }, sub {
    my ($ua, $tx) = @_;

    if ($tx->res->error) {
	    # print Mojo::Util::dumper($tx);
			$promise->reject();
			return;
    }

    $promise->resolve();
    print Mojo::Util::dumper($tx->result->json);
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
      # ConsoleSize => [24,80]
      # Tty => Mojo::JSON->true,

      AutoRemove => Mojo::JSON->true
  };

  $resp = $ua->post($url, {Host => 'docker'}, json => $params);
  print Mojo::Util::dumper($resp->result->json);

  my $cid = $resp->result->json->{Id};

  $url = $base_url->clone->path("containers/$cid/start");
  $resp = $ua->post($url, {Host => 'docker'});

  $url = $base_url->clone->path("containers/$cid/attach");
  $url->query
      ->param('stream', 1)
      ->param('stdout', 1)
      ->param('stdin', 1)
      ->param('stderr', 1)
      ;

  $tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade'});

  my $timer;

  $tx->res->content->unsubscribe('read');
  $tx->res->content->on(read => sub {
      my ($content, $content_bytes) = @_;
      $promise->resolve();

      return unless $GLOBAL_STATE->{state} eq 'wait-for-command';

      if($timer){
        say 'renewing timer';
        Mojo::IOLoop->remove($timer);
      }

      say 'adding timer';
      $timer = Mojo::IOLoop->timer(5 => sub {
        say 'abort command execution';
        $tx->emit('command_expired');
        $tx->completed;
      });

      my @frames = unpack_framed_streams($content_bytes);

      my $found = 0;

      while (@frames){
          my ($stream_type, $stream_size, $stream_content) = splice(@frames, 0, 3);
          $tx->emit('command_stdout', $stream_content) if $STREAM_NAMES{$stream_type} eq 'STDOUT';
          $tx->emit('command_stderr', $stream_content) if $STREAM_NAMES{$stream_type} eq 'STDERR';

          my $mark = $current_mark;
          if($stream_content =~ qr{$mark}) {
              if($timer){
                say 'clearing timer';
                Mojo::IOLoop->remove($timer);
              }
              say 'Finished command';
              $GLOBAL_STATE->{state} = 'started';
          }
      }
  });

  $ua->start($tx, sub {});
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
      $GLOBAL_STATE->{state} = 'wait-for-command';

      $tx->once(found_needle => sub {
        $promise->resolve();
      });

      $tx->once(command_expired => sub {
        $promise->reject();
      });

    });

    # Flush
    $tx->resume;
    $current_cmd = $cmd;
    $current_mark = $end_mark;
    return $promise;
}

sub startup {
	my ($self) = @_;

  $self->routes->get('/' => sub {
      my ($c) = @_;
      $c->render(json => $GLOBAL_STATE);
    });

  $self->routes->post('/start' => sub {
    my ($c) = @_;
    $c->inactivity_timeout(300);
    $GLOBAL_STATE->{state} = 'starting';
    sleep 1;

    stop_container()
      ->then(sub {
        $GLOBAL_STATE->{state} = 'deleting';
        return delete_container()
      })->then(sub {
        $GLOBAL_STATE->{state} = 'stopped';
        return start_container();
      })->then(sub {
        $GLOBAL_STATE->{state} = 'started';
        $c->render(text => 'starting container');
      }, sub {
      	$c->render(text => 'could not delete');
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

    $c->inactivity_timeout(0);
    $GLOBAL_STATE->{state} = 'running-command';
    sleep 1;

    $tx->on('command_stdout', sub {
      my ($e, $line) = @_;

      $c->write(Mojo::JSON::encode_json({
        stdout => $line
        }) . "\n" );
    });

    $tx->on('command_stderr', sub {
      my ($e, $line) = @_;
      $c->write(Mojo::JSON::encode_json({
        stdout => $line
        }) . "\n" );
    });

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
        $tx->unsubscribe('command_stdout');
        $tx->unsubscribe('found_needle');
        $c->finish();
        $GLOBAL_STATE->{state} = 'started';
      });
  });

  $self->routes->post('/stop' => sub {
    my ($c) = @_;
    $c->inactivity_timeout(300);
    
    $GLOBAL_STATE->{state} = 'stopping';
    stop_container()
      ->then(sub {
        $GLOBAL_STATE->{state} = 'deleting';
        return delete_container();
      })->then(sub {
        $GLOBAL_STATE->{state} = 'stopped';
        $c->render(text => 'stopping container');
      }, sub {
      	$c->render(text => 'could not delete');
      });
  });
}

1;
