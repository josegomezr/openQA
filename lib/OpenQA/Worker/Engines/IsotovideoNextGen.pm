# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::Engines::IsotovideoNextGen;
use Mojo::Base 'OpenQA::Worker::Engines::AbstractEngine';
use Data::Dumper;

use constant ENGINE_NAME => 'isotovideo-ng';

sub prepare {
    my ($self, @args) = @_;
    printf 'PREPARING %s\n', ENGINE_NAME;
    map { Dumper($_) } @args;
}

1;
