# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg;
use Mojo::Base -base, 'Mojo::EventEmitter', -strict, -signatures;
use OpenQA::WorkerNg::Constants;
use OpenQA::Client;
use Data::Dumper;
use Hash::Merge;
use Mojo::JSON;

use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKER_COMMAND_QUIT
WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_SR_FINISH_OFF);

# new, registering, establishing_ws, connected, failed, disabled, quit
has exit_status => sub { return OpenQA::WorkerNg::Constants::EXIT_SUCCESS };

has status => sub {
    return 'new';
};

has worker_id => sub {
    return '1';
};

has websocket_url => sub {
    my $self = shift;
    my $worker_id = $self->worker_id;

    return Mojo::URL->new('ws://127.0.0.1:9527/')
        ->path("/ws/$worker_id");
};

has api_url => sub {
    my $self = shift;

    return Mojo::URL->new('http://127.0.0.1:9526/')
        ->path('/api/v1/');
};

has client => sub {
    my $self = shift;

    return OpenQA::Client->new(
        api => $self->api_url,
        apikey => '1234567890ABCDEF',
        apisecret => '1234567890ABCDEF',
    );
};

has 'current_job';
has 'websocket_connection';

sub new {
    my ($class, @attrs) = @_;
    my $self = $class->SUPER::new(@attrs);
    return $self;
}

sub configure_callbacks {
    my ($self) = @_;

    # 
    $self->on(status_change => sub {
        my ($self, $status, $extra_context) = @_;
        $self->on_worker_status_change($status, $extra_context);
    });

    $self->on(grab_job => sub {
        my ($self, $job_info) = @_;
        $self->on_grab_job($job_info);
    });

    $self->on(info => sub {
        my ($self, $job_info) = @_;
        say "     worker-info: " . Mojo::JSON::encode_json($job_info);
    });
}

sub on_grab_job {
    my ($self, $job_info) = @_;

    $self->emit(status_change => 'accepting');
    $self->current_job($job_info->{'job'});

    my $message = {type => 'accepted', jobid => $job_info->{'id'}};

    $self->send_via_ws($message, sub {
        my($self) = @_;
        say '     job has been accepted';
        $self->schedule_work();
    })
}

sub send_via_ws {
    # use Mojo::JSON 'encode_json';
    my ($self, $json, $cb) = @_;

    return undef unless $self->websocket_connection;
    say "WSS: Worker -> openQA: " . Mojo::JSON::encode_json($json);

    $self->websocket_connection->send({json => $json}, sub {
        say "WSS: Worker <- openQA: ACK";
        $cb->($self);
    })
}

sub send_via_rest {
    my $self = shift;
    my ($method, $path, $headers, $body) = @_;

    my $url = $self->api_url->clone->path($path);
    $body = $headers and $headers = {} unless $body;

    $method = uc($method);

    say "API: Worker -> openQA: $method $url " . Mojo::JSON::encode_json($body);
    my $tx = $self->client->build_tx($method, $url, $headers, %$body);
    $self->client->start($tx);
    my $res = $tx->res->body;
    say "API: Worker <- openQA: " . $res;
    
    return $tx;
}

sub on_worker_status_change {
    my ($self, $status, $extra_context) = @_;
    $self->status($status);

    my $message = { type => 'worker_status', status => $status, };

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');

    $message = $merger->merge($message, $extra_context);

    $self->send_via_ws($message, sub {
        if ($status eq 'stopping') {
            $self->complete_job();
        }

        if ($status eq 'quit' || $status eq 'dead') {
            $self->on_worker_stop();
        }
    });
}

sub on_worker_stop {
    my ($self) = @_;

    $self->websocket_connection->finish();
    $self->emit('stop');
}

sub schedule_work {
    my ($self) = @_;
    my $job_id = $self->current_job->{id};
    my $final_work_result;

    my $url = "jobs/$job_id/status";
    my $params = {status => { worker_id => $self->worker_id }};

    $self->send_via_rest(POST => $url, {json => $params});

    Mojo::IOLoop->subprocess->run_p(sub {
        my ($subprocess) = @_;
        map { say $_ } @_;

        say "------- DOING WORK!";
        
        sleep 3;

        say "------- DONE WORK!";

        return 'results here';
    })
    ->then(sub {
        my (@results) = @_;
        say "------- I got!";
        map { say $_ } @results;

        $final_work_result = pop @results;
    })->catch(sub {
        my ($err) = @_;
        say "------- Subprocess error: $err";
    })->finally(sub {
        say "======= Finished job with result: $final_work_result";

        open(my $fh, '>>', '/tmp/result.txt') or die $!;
        say $fh $final_work_result;
        close $fh;

        $self->emit(status_change => 'stopping', {
            reason => 'done'
        });
    });
}

sub complete_job {
    my ($self) = @_;

    my $params = {
        reason => WORKER_SR_DONE,
        result => 'passed'
    };

    # pass the reason if it is an additional specification of the result
    my $job_id = $self->current_job->{'id'};
    $params->{worker_id} = $self->worker_id;

    my $asset = Mojo::Asset::File->new(path => '/tmp/result.txt');
    $asset->slurp;

    $self->send_via_rest(POST => "jobs/$job_id/artefact", {"X-Normal-Upload" => 1} ,{ form => { 
        asset => 'public',
        file => { file => $asset } }, 
    });

    $self->send_via_rest(POST => "jobs/$job_id/set_done", { form => $params });

    $self->current_job(undef);

    $self->emit(status_change => 'stopped', {
        ok => 1,
    });
}

sub compute_capabilities {
    my $capabilities = {
        cpu_arch => 'x86_64',
        cpu_modelname => 'GeniuneIntel',
        cpu_opmode => '32-bit, 64-bit',
        cpu_flags => 'fpu vme de pse tsc msr',
        mem_max => 32795,
        worker_class => 'qemu_x86_64',
        host => 'guaiqueri',
        instance => '1',
        websocket_api_version => WEBSOCKET_API_VERSION,
    };

    return $capabilities;
}

sub register {
    my $self = shift;
    return undef unless $self->register_rest_api();
    return undef unless $self->start_ws_conn();
    return $self;
}

sub register_rest_api {
    my $self = shift;
    my $capabilities = compute_capabilities;
    my $url = "workers";

    # say "Registering Worker to: " . $url->host_port;
    # my $tx = $self->send_via_rest(POST => $url, {json => $capabilities});
    #                                              ^^^^
    #                                              doesn't work

    my $tx = $self->send_via_rest(POST => $url, {form => $capabilities});
    # Bail when registering fails
    return $self->handle_worker_register_error($tx) if ($tx->error);

    my $worker_id = $tx->res->json->{'id'};

    # say "Successfully registered in: " . $url->host_port;
    # say "Assigned worker-id: $worker_id";
    $self->worker_id($worker_id);
}

sub handle_worker_register_error {
    my ($self, $tx) = @_;

    my $error = $tx->error;
    my $json_res = $tx->res->json;

    my $error_code = $error->{code};
    my $error_class = $error_code ? "$error_code response" : 'connection error';
    my $error_message;
    $error_message = $json_res->{error} if ref($json_res) eq 'HASH';
    $error_message //= $tx->res->body || $error->{message};
    $error_message = "Failed to register at ".$self->api_url." - $error_class: $error_message";
    
    my $status = (defined $error_code && $error_code =~ /^4\d\d$/ ? 'disabled' : 'failed');

    if ($error_message =~ /timestamp mismatch - check whether clocks on the local host and the web UI host are in sync/) {
        $status = 'failed';
    }

    say $error_message;
    $self->exit_status(OpenQA::WorkerNg::Constants::EXIT_ERR_ANNOUNCE);
    $self->cleanup();
}

sub start_ws_conn {
    my $self = shift;
    my $url = $self->websocket_url;

    say "Initiating Websockets connection to $url";
    my $ua = $self->client;
    
    $ua->max_connections(0)
        ->max_redirects(3);

    $ua->websocket($url, {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub ($ua, $tx) {
        if(!$tx->is_websocket){
            say 'WebSocket handshake failed!';
            $self->exit_status(OpenQA::WorkerNg::Constants::EXIT_ERR_WS);
            $self->cleanup();
            return;
        }

        $self->websocket_connection($tx);
        $self->configure_callbacks();

        $self->emit(status_change => 'connected');

        $self->websocket_connection->on(json => sub ($tx, $json) {
            say "WSS: OpenQA -> Worker: " . Mojo::JSON::encode_json($json);
            $self->emit($json->{type} => $json);
        });
    });
}

sub cleanup {
    my $self = shift;
    say "WORKER CLEANUP";

    return unless $self->websocket_connection;

    $self->send_via_ws({type => 'quit'}, sub {
        $self->websocket_connection->finish();
        $self->websocket_connection(undef);
        Mojo::IOLoop->stop;
    });
}

sub configure_signal_handlers {
    my $self = shift;
    $SIG{HUP} = sub {
        $self->handle_signals('HUP');
    };
    $SIG{TERM} = sub {
        $self->handle_signals('TERM');
    };
    $SIG{INT} = sub {
        $self->handle_signals('INT');
    };
}

sub handle_signals { 
    my $self = shift;
    my ($signal) = @_;
    say "caught: $signal";
    $self->cleanup();
}

1;
