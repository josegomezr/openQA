# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg::Helper;

sub host_and_proto_of {
    my ($self) = @_;
    return sprintf("%s://%s", $self->scheme, $self->host_port);
}
1;
