# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg::Capabilities;
use strict;
use warnings;
use POSIX qw(uname);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION);
use v5.26;
use Sys::Hostname;

sub lscpu {
    my $lscpu = {};
    my $out = `LC_ALL=C lscpu -J`;
    my $json = Mojo::JSON::decode_json($out)->{lscpu};
    foreach my $pair (@$json) {
        my $key = substr(lc($pair->{field}), 0, -1);
        $lscpu->{$key} = $pair->{data};
    }
    return $lscpu;
}

sub cpu_arch {
    my @uname = uname();
    return $uname[4];
}
sub mem_max {
    my $lsmem = `lsmem --output=SIZE -r -b | tail -n +2`;
    my $total = 0;
    map { $total += $_ } split("\n", $lsmem);
    return int($total / (1024 ^ 2));
}

sub worker_class {
    return 'qemu_x86_64';
}

sub compute_capabilities {
    my $lscpu = lscpu();

    my $capabilities = {
        cpu_arch => cpu_arch(),
        cpu_modelname => $lscpu->{'model name'},
        cpu_opmode => $lscpu->{'cpu op-mode(s)'},
        cpu_flags => $lscpu->{'flags'},
        mem_max => mem_max(),
        worker_class => worker_class(),
        host => hostname(),
        instance => '1',
        websocket_api_version => WEBSOCKET_API_VERSION,
    };

    return $capabilities;
}
1;
