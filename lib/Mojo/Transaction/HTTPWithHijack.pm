=encoding utf8

=head1 NAME

Mojo::Transaction::HTTPWithHijack - Transport-Hijack-aware Transaction

=head1 SYNOPSIS
  
  use Mojo::UserAgent;
  use Mojo::URL;
  use Mojo::Transaction::HTTPWithHijack;

  $base_url = Mojo::URL->new("%your-docker/podman-socket-location%/v1.43")->path('/containers');
  $url = $base_url->clone->path("containers/%container-id%/attach");
  $tx = $ua->build_tx(POST => $url => {Host => 'docker', Connection => 'Upgrade', Upgrade => 'tcp'});
  # Decorate the transaction with HTTP Hijack implementation.
  $tx = Mojo::Transaction::HTTPWithHijack->new($container_tx);

  # Begin streaming the response
  $tx->res->content->unsubscribe('read');
  $tx->res->content->on(
      read => sub ($content, $stream) {
        # do something with $stream here.
      });


=head1 DESCRIPTION

C<Mojo::Transaction::HTTPWithHijack> is a C<Mojo::Transaction::HTTP> implementing
Transport Hijacking.

- https://docs.docker.com/engine/api/v1.43/#tag/Container/operation/ContainerUnpause
- https://docs.podman.io/en/latest/_static/api.html#tag/containers/operation/ContainerAttachLibpod

=cut

package Mojo::Transaction::HTTPWithHijack;
use Mojo::Base 'Mojo::Transaction::HTTP';
use Mojo::Util ();

=head2 _is_a_hijack_response
  
  # private
  $tx->_is_a_hijack_response($res);

Determines if a response is a transport hijacking response.

There are two types of response that can trigger Transport Hijacking, they are:

Implicit: HTTP 200 + Content-Type:

  HTTP/1.1 200 OK
  Content-Type: application/vnd.docker.raw-stream

Explicit: HTTP 101 Upgrade
  
  HTTP/1.1 101 UPGRADED
  Content-Type: tcp
  Connection: Upgrade
  Upgrade: application/vnd.docker.raw-stream

=cut

sub _is_a_hijack_response {
  my ($res) = @_;

  # Test the explicit path:
  if ($res->is_info) {
    my $is_docker_stream = ($res->headers->upgrade // '-') eq 'application/vnd.docker.raw-stream';
    my $is_tcp = ($res->headers->content_type // '-') eq 'tcp';
    
    return $is_tcp && $is_docker_stream;
  }

  # Test the implicit path:
  if($res->is_success) {
    my $is_tcp = ($res->headers->content_type // '-') eq 'application/vnd.docker.raw-stream';
    return $is_tcp;
  }
}

=head2 client_read

  $tx->client_read($bytes);

Read data client-side, and performs transport hijacking when applicable.

=cut

sub client_read {
  my ($self, $chunk) = @_;

  # Skip body for HEAD request
  my $res = $self->res;
  $res->content->skip_body(1) if uc $self->req->method eq 'HEAD';

  return undef unless $res->parse($chunk)->is_finished;

  # ~~ Custom Code ~~
  # Hijack (keep the connection open) when applicable.
  if (_is_a_hijack_response($res)){
    # the first chunk received is just headers. We don't do anything with them
    # besides detection, so: Dropping it...
    $chunk = '' unless $res->{hijacked};

    # Mark the request
    $res->{hijacked} = 1;
    # Send the data
    $res->content->emit(read => $chunk);
    # Stop here, wait for more
    return undef;
  }
  # ~/ Custom Code ~~

  # Unexpected 1xx response
  return $self->completed if !$res->is_info || $res->headers->upgrade;
  $self->res($res->new)->emit(unexpected => $res);
  return undef unless length(my $leftovers = $res->content->leftovers);
  $self->client_read($leftovers);
}

1;