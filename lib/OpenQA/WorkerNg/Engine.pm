package OpenQA::WorkerNg::Engine;
use Mojo::Base -base, 'Mojo::EventEmitter', -strict, -signatures;

use Data::Dumper qw(Dumper);

use Mojo::URL ();
use Mojo::Log ();
use Mojo::Server::Daemon ();
use OpenQA::CommandServerNg ();

has logger => sub {
    return Mojo::Log->new(color => 1)->context('engine');
};

has command_server_addr => sub {
	# Listen on 127.Q.A.E
	# QA Engine.
	#
	# I should spend time in other things...
	#
	# 0x
	#   127 => loopback
	#   51  => Q
	#   41  => A
	#   45  => E
	return Mojo::URL->new('http://127.51.41.45:9999');
};

has control_socket_path => sub {
    my ($self) = @_;
	return $self->work_dir . '/control.sock';
};

has command_server => sub {
    return OpenQA::CommandServerNg->new();
};

has command_server_daemon => sub {
    my ($self) = @_;
    my $server = Mojo::Server::Daemon->new()->app($self->command_server);
    $server->listen([
    	$self->command_server_addr,
    	Mojo::URL->new->scheme('http+unix')->host($self->control_socket_path)
    ]);
    return $server;
};

has work_dir => undef;

sub start_command_server {
    my ($self) = @_;
    $self->command_server_daemon->start();
    $self->logger->info("Listening on:" . $self->control_socket_path);
}

sub stop_command_server {
    my $self = shift;
    $self->logger->info("stopping command server");
    $self->command_server->stop_container()->then(sub {
    	return $self->command_server->delete_container();
    })->catch(sub {})->finally(sub {
    	$self->command_server_daemon->stop();
    });
}

sub start {
	my ($self, $config_params) = @_;
	Dumper($config_params);
	$self->work_dir($config_params->{work_dir});

	$self->start_command_server();
	# receive some sort of properties to configure the initial container
	# everything is hardcoded to leap running sh right now.

	# hack here: force stop a previous container, in dev happens a lot
	# in prod prolly never happens.
	return $self->command_server->stop_container()->then(sub {
			return $self->command_server->delete_container();
		})->catch(sub {})->then(sub {
			return $self->command_server->run_container();
		});

	# return $self->command_server->run_container();
}

sub stop {
	my $self = shift;
	$self->stop_command_server();

	$self->work_dir(undef);
}

1;