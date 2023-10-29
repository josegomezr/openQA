# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg;
use Mojo::Base -base, 'Mojo::EventEmitter', -strict, -signatures, 'OpenQA::WorkerNg::Capabilities';
use OpenQA::WorkerNg::Constants ();
use OpenQA::Client ();
use Data::Dumper qw(Dumper);
use Hash::Merge ();
use Mojo::JSON ();
use Mojo::Log ();

use OpenQA::Constants qw(WORKER_SR_DONE);
use OpenQA::WorkerNg::Helper ();

# new, registering, establishing_ws, connected, failed, disabled, quit
has exit_status => sub { return OpenQA::WorkerNg::Constants::EXIT_SUCCESS };
has livelog_status => sub { 0 };

has logger => sub {
    return Mojo::Log->new(color => 1)->context('worker');
};

has status => sub {
    return OpenQA::WorkerNg::Constants::WS_STATUS_INIT;
};

has api_url => sub {
    my $self = shift;

    return Mojo::URL->new('http://127.0.0.1:9526/')->path('/api/v1/');
};

has client => sub {
    my $self = shift;

    return OpenQA::Client->new(
        api => $self->api_url,
        apikey => '1234567890ABCDEF',
        apisecret => '1234567890ABCDEF',
    );
};

has worker_id => undef;
has current_job => undef;
has websocket_connection => undef;

sub new {
    my ($class, @attrs) = @_;
    my $self = $class->SUPER::new(@attrs);
    return $self;
}

sub run {
    my ($self) = @_;

    $self->logger->info("Starting Worker");
    $self->logger->info("Connecting to OpenQA Instance");
    $self->logger->info(sprintf("REST+WS API %s", OpenQA::WorkerNg::Helper::host_and_proto_of($self->api_url)));

    return undef unless $self->authenticate();
    $self->logger->trace("Identified as Worker-ID: " . $self->worker_id);
    return undef unless $self->connect_to_broker();

    $self->configure_callbacks();
}

sub start_livelog {
    my ($self, $job_info) = @_;
    my $job_id = $job_info->{jobid};

    $self->logger->trace("[livelog] Start live log for job: $job_id");
    $self->livelog_status(1);
}

sub stop_livelog {
    my ($self, $job_info) = @_;
    my $job_id = $job_info->{jobid};

    $self->logger->trace("[livelog] Stop live log for job: $job_id");
    $self->livelog_status(1);
}

sub job_grab {
    my ($self, $message) = @_;

    $self->emit(
        status_change => OpenQA::WorkerNg::Constants::WS_STATUS_ACCEPTING,
        {
            job_id => $message->{job}->{id}
        },
        sub {
            $self->job_can_grab($message);
        });
}

sub configure_callbacks {
    my ($self) = @_;

    # Worker Status State Machine
    # Every time the worker status changes, the broker must be notified.
    $self->on(
        status_change => sub {
            my ($self, $status, $extra_context, $cb) = @_;
            $self->logger->trace(sprintf("transition from '%s' to '%s'", $self->status, $status));
            $self->sync_worker_status($status, $extra_context, $cb);
        });

    # OpenQA Commands
    # This handles all comms coming from the worker broker to the worker.
    # OpenQA -- [$message] -> Worker

    $self->on(
        OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND => sub {
            my ($self, $json) = @_;
            my $message = $json->{type};

            $self->logger->context('worker', 'ws')
              ->info("OpenQA -- [$message] -> Worker: " . Mojo::JSON::encode_json($json));

            # I'm sure there's a more elegant way to do this, but if-elses will sufice

            if ($message eq OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND_GRAB_JOB) {
                $self->job_grab($json);
            }

            if ($message eq OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND_INFO) {
                $self->logger->trace("    INFO:" . Mojo::JSON::encode_json($json));
            }

            if ($message eq OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND_LIVELOG_STOP) {
                $self->start_livelog($json);
            }

            if ($message eq OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND_LIVELOG_START) {
                $self->stop_livelog($json);
            }
        });

}

sub job_can_grab {
    my ($self, $job_info) = @_;
    return $self->accept_job($job_info);

    # return $self->job_reject($job_info);
}

sub job_reject {
    my ($self, $job_info) = @_;
    my $job_id = $job_info->{'job'}->{'id'};
    my $message = {job_ids => [$job_id]};
    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_REJECT_JOBS,
        $message,
        sub {
            my ($self) = @_;
            $self->logger->info("job $job_id has been rejected");

            $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_FREE);
        });
}

sub job_post_status {
    my ($self) = @_;
    my $job_id = $self->current_job->{'id'};

    my $uri = "jobs/$job_id/status";

    my $params = {status => {worker_id => $self->worker_id}};
    $self->send_via_rest(POST => $uri, {json => $params});
}

sub accept_job {
    my ($self, $job_info) = @_;

    $self->current_job($job_info->{'job'});
    my $job_id = $self->current_job->{'id'};
    my $message = {jobid => $job_id};

    # Notify via Websockets that we're taking the job, then notify via REST
    #
    # Websockets *has* to be first, then REST, else REST fails because worker
    # is not associated yet.
    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_ACCEPT_JOB,
        $message,
        sub {
            my ($self) = @_;
            $self->logger->info("job $job_id has been accepted");

            $self->job_post_status();
            $self->engine_start();
        });
}

sub send_via_ws {
    # use Mojo::JSON 'encode_json';
    my ($self, $type, $json, $cb) = @_;

    return undef unless $self->websocket_connection;

    $self->logger->context('worker', 'ws')->trace("-- [$type] -> openQA: " . Mojo::JSON::encode_json($json));

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');
    $json = $merger->merge(
        $json,
        {
            type => $type
        });

    $self->websocket_connection->send(
        {json => $json},
        sub {
            $self->logger->context('worker', 'ws')->trace("<- [$type] - openQA: ACK");
            $cb->($self) if $cb;
        });
}

sub send_via_rest {
    my ($self, $method, $path, $headers, $body) = @_;

    my $url = $self->api_url->clone->path($path);
    $body = $headers and $headers = {} unless $body;

    $method = uc($method);

    $self->logger->context('worker', 'api')->trace("-> openQA: $method /$path " . Mojo::JSON::encode_json($body));
    my $tx = $self->client->build_tx($method, $url, $headers, %$body);
    $self->client->start($tx);
    my $res = $tx->res->body;

    $self->logger->context('worker', 'api')->trace("<- openQA: " . $res);

    return $tx;
}

sub sync_worker_status {
    my ($self, $status, $extra_context, $cb) = @_;
    $self->status($status);

    my $message = {status => $status,};

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');

    $message = $merger->merge($message, $extra_context);

    $self->send_via_ws(
        OpenQA::WorkerNg::Constants::WS_WORKER_COMMAND_WORKER_STATUS,
        $message,
        sub {
            $cb->($self) if $cb;
        });
}

sub engine_start {
    my ($self) = @_;
    my $job_id = $self->current_job->{id};

    # notify openqa we started working
    $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_WORKING);

    my $logger = $self->logger->context('worker-subprocess');

    $logger->info("---- [parent] START OF WORK ----");

    my $subprocess = Mojo::IOLoop->subprocess->run(
        sub {
            my ($subprocess) = @_;
            my $pid = $subprocess->pid;
            $logger->info("---- [child] START OF WORK ----");

            # Mimic some work
            map { $subprocess->progress("First: log line: $_") and sleep 0.1; } (1, 2, 3, 4, 5, 6, 7, 8, 9, 10);

            $logger->info("---- [child] END OF WORK ----");
        },
        sub {
            my ($subprocess, $err, @results) = @_;
            my $pid = $subprocess->pid;

            $logger->info("---- [parent] END OF WORK ----");

            $self->emit(
                status_change => OpenQA::WorkerNg::Constants::WS_STATUS_STOPPING,
                {
                    reason => 'done'
                },
                sub {
                    # Upload job results
                    $self->job_complete();
                });
        });

    $subprocess->on(
        spawn => sub {
            my ($subprocess) = @_;
            my $pid = $subprocess->pid;
            $logger->info("Spawning process $pid | \$\$: " . $$);
        });

    $subprocess->on(
        progress => sub {
            my ($subprocess, @data) = @_;
            my $pid = $subprocess->pid;
            $logger->info(": $pid | \$\$: ", $$, " ", @data);

            if ($self->livelog_status) {
                $self->logger->info("  ??: Livelog: ", @data);
            }
        });

    $subprocess->on(
        cleanup => sub {
            my ($subprocess) = @_;
            my $pid = $subprocess->pid;
            $logger->info(" | PID: $pid \$\$: ", $$);
        });
}

sub job_upload_artifacts {
    my ($self) = @_;

    my $job_id = $self->current_job->{'id'};
    my $asset = Mojo::Asset::File->new(path => '/tmp/result.txt');
    $asset->slurp;

    $self->send_via_rest(
        POST => "jobs/$job_id/artefact",
        {"X-Normal-Upload" => 1},
        {
            form => {
                asset => 'public',
                file => {file => $asset}
            },
        });
}

# Mark a job as done
sub job_complete {
    my ($self) = @_;

    my $params = {
        reason => WORKER_SR_DONE,
        result => 'passed'
    };

    # pass the reason if it is an additional specification of the result
    my $job_id = $self->current_job->{'id'};

    $self->job_upload_artifacts();

    $params->{worker_id} = $self->worker_id;
    $self->send_via_rest(POST => "jobs/$job_id/set_done", {form => $params});

    $self->emit(
        status_change => OpenQA::WorkerNg::Constants::WS_STATUS_STOPPED,
        {
            ok => 1
        },
        sub {
            $self->current_job(undef);
            $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_FREE);
        });
}

sub authenticate {
    my $self = shift;
    my $capabilities = $self->compute_capabilities();
    my $url = 'workers';

    # $self->logger->info("Registering Worker to: " . $url->host_port);
    # my $tx = $self->send_via_rest(POST => $url, {json => $capabilities});
    #                                              ^^^^
    #                                              doesn't work

    my $tx = $self->send_via_rest(POST => $url, {form => $capabilities});
    # Bail when registering fails
    if ($tx->error) {
        $self->handle_connection_error($tx);
        $self->exit_status(OpenQA::WorkerNg::Constants::EXIT_ERR_ANNOUNCE);
        $self->disconnect();

        return;
    }

    my $worker_id = $tx->res->json->{'id'};

    $self->logger->info("Successfully registered");
    $self->logger->trace("Assigned worker-id: $worker_id");
    $self->worker_id($worker_id);
}

sub handle_connection_error {
    my ($self, $tx) = @_;
    my $error = $tx->error;
    my $error_code = $error->{code};

    my $message = 'Connection error: ';
    $message = "HTTP Error $error_code: " if ($error_code);

    $message .= $error->{message};
    if ($tx->res->body) {
        $message .= "\n";
        $message .= '';
        $message .= "Response: " . $tx->res->body;
    }

    my $failing_endpoint = Mojo::URL->new($tx->req->url);
    $message .= "\n";
    $message .= "Failed to connect to: " . OpenQA::WorkerNg::Helper::host_and_proto_of($failing_endpoint);

    $self->logger->error($message);
}

sub connect_to_broker {
    my $self = shift;
    my $worker_id = $self->worker_id;
    my $url = $self->api_url->clone->path("ws/$worker_id");

    if ($self->websocket_connection) {
        $self->logger->info("Disconnecting current ws");
        $self->websocket_connection->finish();
        $self->websocket_connection(undef);
    }

    $self->logger->info("Initiating Websockets connection");
    my $ua = $self->client;

    $ua->max_connections(0)->max_redirects(3);

    $ua->websocket(
        $url,
        {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;

            if (!$tx->is_websocket) {
                $self->logger->info('WebSocket handshake failed!');
                $self->handle_connection_error($tx);
                $self->exit_status(OpenQA::WorkerNg::Constants::EXIT_ERR_WS);
                $self->disconnect();
                return;
            }

            $self->websocket_connection($tx);

            $self->emit(
                status_change => OpenQA::WorkerNg::Constants::WS_STATUS_CONNECTED,
                {},
                sub {
                    # Signal that we're ready
                    $self->emit(status_change => OpenQA::WorkerNg::Constants::WS_STATUS_FREE);
                });

            $self->websocket_connection->on(
                finish => sub {
                    my ($ws, $code, $reason) = @_;

                    $self->logger->context('worker', 'ws')->info("closed connection with code: $code");
                });

            $self->websocket_connection->on(
                json => sub {
                    my ($tx, $json) = @_;
                    $self->emit(OpenQA::WorkerNg::Constants::WS_OPENQA_COMMAND => $json);
                });
        });
}

# TODO: separate this into more atomic parts
#       IO Loop can be taken out
sub disconnect {
    my $self = shift;
    $self->logger->info("WORKER disconnect");

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
    $self->logger->info("caught: $signal");
    $self->disconnect();
}

1;
