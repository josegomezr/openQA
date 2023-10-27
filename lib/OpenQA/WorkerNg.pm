# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg;
use Mojo::Base -base, 'Mojo::EventEmitter', -strict, -signatures;
use OpenQA::Client;
use Data::Dumper;
use Hash::Merge;

use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKER_COMMAND_QUIT
WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_SR_FINISH_OFF);

# new, registering, establishing_ws, connected, failed, disabled, quit
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

    $self->on(boot => sub {
        my ($self) = @_;
        $self->register();
    });

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
    });
}

sub on_grab_job {
    my ($self, $job_info) = @_;

    $self->emit(status_change => 'accepting');
    $self->current_job($job_info->{'job'});

    my $message = {type => 'accepted', jobid => $job_info->{'id'}};

    $self->websocket_connection->send({json => $message}, sub {
        say 'job has been accepted';
        $self->schedule_work();
    })
}

sub on_worker_status_change {
    my ($self, $status, $extra_context) = @_;
    $self->status($status);

    my $message = { type => 'worker_status', status => $status, };

    my $merger = Hash::Merge->new('LEFT_PRECEDENT');

    $message = $merger->merge($message, $extra_context);

    $self->websocket_connection->send({json => $message}, sub {
        say "Reported status: $status";

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

    say 'START LONG RUNNING TASK';
    sleep 3;

    $self->emit(status_change => 'stopping', {
        reason => WORKER_SR_DONE
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
    
    my $url = $self->api_url->path("jobs/$job_id/set_done");

    say "-JOB-: " . Dumper($self->current_job);

    $self->client->post($url, form => $params);

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
    my $capabilities = compute_capabilities;
    my $url = $self->api_url->path('workers');
    
    say "Registering Worker to: " . $url->host_port;
    # my $tx = $self->client->post($url, json => $capabilities);
    #                                    ^^^^
    #                                    doesn't work
    my $tx = $self->client->post($url, form => $capabilities);

    # Bail when registering fails
    return $self->handle_worker_register_error($tx) if ($tx->error);

    my $worker_id = $tx->res->json->{'id'};

    say "Successfully registered in: " . $url->host_port;
    say "Assigned worker-id: $worker_id";
    $self->worker_id($worker_id);

    initiate_ws_conn($self);
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
    $error_message = "Failed to register at {$self->api_url} - $error_class: $error_message";
    
    my $status = (defined $error_code && $error_code =~ /^4\d\d$/ ? 'disabled' : 'failed');

    if ($error_message =~ /timestamp mismatch - check whether clocks on the local host and the web UI host are in sync/) {
        $status = 'failed';
    }

    say $error_message;
    exit 1;
}

sub initiate_ws_conn {
    my $self = shift;
    my $url = $self->websocket_url;

    say "Initiating Websockets connection to $url";
    my $ua = $self->client;
    
    $ua->max_connections(0)
        ->max_redirects(3);

    $ua->websocket($url, {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub ($ua, $tx) {
        say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
        
        $self->websocket_connection($tx);
        $self->configure_callbacks();

        $self->emit(status_change => 'connected');

        $tx->on(json => sub ($tx, $hash) {
            say "WS-Arrived: " . Dumper($hash);
            $self->emit($hash->{type} => $hash);
        });
    });
}
1;
