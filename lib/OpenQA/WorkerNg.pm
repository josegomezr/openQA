# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg;
use Mojo::Base -base, 'Mojo::EventEmitter', -strict, -signatures;
use OpenQA::WorkerNg::Constants ();
use OpenQA::Client ();
use Data::Dumper qw(Dumper);
use Hash::Merge ();
use Mojo::JSON ();

use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKER_SR_DONE);

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
has 'retry_delay' => sub { 5 };

my $callbacks = 0;

sub new {
    my ($class, @attrs) = @_;
    my $self = $class->SUPER::new(@attrs);
    return $self;
}

my $counter = 0;

sub configure_callbacks {
    my ($self) = @_;

    return undef if $callbacks;
    $callbacks = 1;

    $self->on(status_change => sub {
        my ($self, $status, $extra_context, $cb) = @_;
        say sprintf("Worker [log]: transition from '%s' to '%s'", $self->status, $status);
        $self->on_worker_status_change($status, $extra_context, $cb);
    });

    $self->on(openqa_grab_job => sub {
        my ($self, $job_info) = @_;

        # $self->on_reject_job($job_info);

        $self->on_grab_job($job_info);
    });

    $self->on(openqa_info => sub {
        my ($self, $job_info) = @_;
        say "     worker-info: " . Mojo::JSON::encode_json($job_info);
    });
}

sub on_reject_job {
    my ($self, $job_info) = @_;
    my $message = { job_ids => [$job_info->{'job'}->{'id'}] };
    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_REJECT_JOBS,
        $message,
        sub {
            my($self) = @_;
            say '     job has been rejected';

            $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_FREE);
        });
}

sub on_grab_job {
    my ($self, $job_info) = @_;

    $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_ACCEPTING);
    $self->current_job($job_info->{'job'});

    my $message = { jobid => $job_info->{'job'}->{'id'} };

    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_ACCEPT_JOB,
        $message,
        sub {
            my($self) = @_;
            say '     job has been accepted';
            $self->schedule_work();
        });
}

sub send_via_ws {
    # use Mojo::JSON 'encode_json';
    my ($self, $type, $json, $cb) = @_;

    return undef unless $self->websocket_connection;
    # sleep 5;
    say "  WSS: Worker -- [$type] -> openQA: " . Mojo::JSON::encode_json($json);

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');
    $json = $merger->merge($json, {
        type => $type
    });

    $self->websocket_connection->send({json => $json}, sub {
        say "  WSS: Worker <- [$type] - openQA: ACK";
        $cb->($self) if $cb;
    })
}

sub send_via_rest {
    my ($self, $method, $path, $headers, $body) = @_;

    my $url = $self->api_url->clone->path($path);
    $body = $headers and $headers = {} unless $body;

    $method = uc($method);

    # sleep 5;
    say "  API: Worker -> openQA: $method $url " . Mojo::JSON::encode_json($body);
    my $tx = $self->client->build_tx($method, $url, $headers, %$body);
    $self->client->start($tx);
    my $res = $tx->res->body;
    say "  API: Worker <- openQA: " . $res;
    
    return $tx;
}

sub on_worker_status_change {
    my ($self, $status, $extra_context, $cb) = @_;
    $self->status($status);

    my $message = { status => $status, };

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');

    $message = $merger->merge($message, $extra_context);

    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_WORKER_STATUS,
        $message,
        sub {
            $cb->($self) if $cb;

            if ($status eq 'stopping') {
                # $self->send_job_results();
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

    say "Worker [log]: Signal openQA we're taking job $job_id";
    {
        my $url = "jobs/$job_id/status";
        my $params = {status => { worker_id => $self->worker_id }};
        $self->send_via_rest(POST => $url, {json => $params});
    }

    say "Worker [log]: Signal openQA we're working";
    {
        $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_WORKING);
    }
    
    say "Worker [log]: [SUBPROCESS-PRE] BEGIN WORK (FORKING) " . $$;

    my $subprocess = Mojo::IOLoop->subprocess->run(sub {
        my ($subprocess) = @_;
        my $pid = $subprocess->pid;
        say "Worker [log]: [SUBPROCESS-CHILD]: PID $pid | \$\$: " . $$;

        # my $stream = Mojo::IOLoop::Stream->new($handle);
        # $stream->on(read => sub ($stream, $bytes) {...});
        # $stream->on(close => sub ($stream) {...});
        # $stream->on(error => sub ($stream, $err) {...});

        map { $subprocess->progress("log line: $_") and sleep 1; } (1, 2, 3, 4, 5, 6);

        sleep 30;
        say "Worker [log]: [SUBPROCESS-CHILD]: PID $pid | \$\$: " . $$ . " ---- STOP ----";
        
    }, sub {
        my ($subprocess, $err, @results) = @_;
        my $pid = $subprocess->pid;

        say "Worker [log]: [SUBPROCESS-CHILD-END] [PARENT]  $pid | \$\$: " . $$;

        $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_STOPPING, {
            reason => 'done'
        }, sub {
            # Upload job results
            $self->send_job_results();
        });
    });

    $subprocess->on(spawn => sub {
        my ($subprocess) = @_;
        my $pid = $subprocess->pid;
        say "Worker [log]: [SUBPROCESS-SPAWN]: Performing work in process $pid | \$\$: " . $$;
    });

    $subprocess->on(progress => sub {
        my ($subprocess, @data) = @_;
        my $pid = $subprocess->pid;
        say "Worker [log]: [SUBPROCESS-PROGRESS]: $pid | \$\$: ", $$, " ", @data;
    });

    $subprocess->on(cleanup => sub {
        my ($subprocess) = @_;
        my $pid = $subprocess->pid;
        say "Worker [log]: [SUBPROCESS-CLEANUP] | PID: $pid \$\$: ", $$;
    });
}

sub upload_artifacts {
    my ($self) = @_;
    
    my $job_id = $self->current_job->{'id'};
    my $asset = Mojo::Asset::File->new(path => '/tmp/result.txt');
    $asset->slurp;

    $self->send_via_rest(POST => "jobs/$job_id/artefact", {"X-Normal-Upload" => 1} ,{ form => { 
        asset => 'public',
        file => { file => $asset } }, 
    });
}

sub save_job_results {
    my ($self) = @_;
    
    my $job_id = $self->current_job->{'id'};
    my $asset = Mojo::Asset::File->new(path => '/tmp/result.txt');
    $asset->slurp;

    $self->send_via_rest(POST => "jobs/$job_id/artefact", {"X-Normal-Upload" => 1} ,{ form => { 
        asset => 'public',
        file => { file => $asset } }, 
    });
}

sub send_job_results {
    my ($self) = @_;

    my $params = {
        reason => WORKER_SR_DONE,
        result => 'passed'
    };

    # pass the reason if it is an additional specification of the result
    my $job_id = $self->current_job->{'id'};

    $self->upload_artifacts();

    $params->{worker_id} = $self->worker_id;
    $self->send_via_rest(POST => "jobs/$job_id/set_done", { form => $params });

    $self->current_job(undef);

    $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_STOPPED, {
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

    if ($self->websocket_connection) {
        say "Worker [log]: Disconnecting current ws";
        $self->websocket_connection->finish();
        $self->websocket_connection(undef);
    }

    say "Worker [log]: Initiating Websockets connection to $url";
    my $ua = $self->client;
    
    $ua->max_connections(0)
        ->max_redirects(3);

    $ua->websocket($url, {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
        my ($ua, $tx) = @_;

        if(!$tx->is_websocket){
            say 'Worker [log]: WebSocket handshake failed!';
            $self->exit_status(OpenQA::WorkerNg::Constants::EXIT_ERR_WS);
            $self->cleanup();
            return;
        }

        $self->websocket_connection($tx);
        $self->configure_callbacks();

        $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_CONNECTED);

        $self->websocket_connection->on(finish => sub {
            my ($ws, $code, $reason) = @_;

            say "  WSS: closed connection with code: $code";
            # say "  WSS: retrying in " . $self->retry_delay;
            
            # Mojo::IOLoop->timer($self->retry_delay, sub {
            #     $self->start_ws_conn();
            # });
        });

        $self->websocket_connection->on(json => sub {
            my ($tx, $json) = @_;
            # sleep 5;
            say "  WSS: OpenQA -> Worker: " . Mojo::JSON::encode_json($json);
            my $event_name = "openqa_" . $json->{type};
            $self->emit( $event_name => $json);
        });
    });
}

sub cleanup {
    my $self = shift;
    say "WORKER CLEANUP";

    return unless $self->websocket_connection;

    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_QUIT,
        {},
        sub {
            $self->websocket_connection->finish() if $self->websocket_connection;
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
