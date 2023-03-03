# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Script::CloneJob;

use Mojo::Base -strict, -signatures;

use Cpanel::JSON::XS;
use Data::Dump 'pp';
use Exporter 'import';
use LWP::UserAgent;
use OpenQA::Client;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::JSON;    # booleans
use OpenQA::Script::CloneJobSUSE;

our @EXPORT = qw(
  clone_jobs
  clone_job_apply_settings
  clone_job_get_job
  clone_job_download_assets
  create_url_handler
  split_jobid
  post_jobs
);

use constant GLOBAL_SETTINGS => ('WORKER_CLASS');

use constant JOB_SETTING_OVERRIDES => {
    _GROUP => '_GROUP_ID',
    _GROUP_ID => '_GROUP',
};

sub is_global_setting ($key) { grep /^$key$/, GLOBAL_SETTINGS }

sub clone_job_apply_settings ($argv, $depth, $settings, $options) {
    delete $settings->{NAME};    # usually autocreated

    for my $arg (@$argv) {
        # split arg into key and value
        unless ($arg =~ /([A-Z0-9_]+\+?)=(.*)/) {
            warn "arg '$arg' does not match";
            next;
        }
        my ($key, $value) = ($1, $2);

        next unless is_global_setting($key) || $depth <= 1 || $options->{'parental-inheritance'};

        # delete key if value empty
        if (!defined $value || $value eq '') {
            delete $settings->{$key};
            next;
        }

        # allow appending via `+=`
        if (substr($key, -1) eq '+') {
            $key = substr $key, 0, -1;
            $value = ($settings->{$key} // '') . $value;
        }

        # assign value to key, delete overrides
        $settings->{$key} = $value;
        if (my $override = JOB_SETTING_OVERRIDES->{$key}) {
            delete $settings->{$override};
        }
    }
}

sub clone_job_get_job ($jobid, $url_handler, $options) {
    my $url = $url_handler->{remote_url}->clone;
    $url->path("jobs/$jobid");
    my $tx = $url_handler->{remote}->max_redirects(3)->get($url);
    if ($tx->error) {
        my $err = $tx->error;
        # there is no code for some error reasons, e.g. 'connection refused'
        $err->{code} //= '';
        die "failed to get job '$jobid': $err->{code} $err->{message}";
    }
    if ($tx->res->code != 200) {
        warn sprintf("unexpected return code: %s %s", $tx->res->code, $tx->res->message);
        exit 1;
    }
    my $job = $tx->res->json->{job};
    print STDERR Cpanel::JSON::XS->new->pretty->encode($job) if $options->{verbose};
    return $job;
}

sub _job_setting_is ($job, $key, $expected_value) {
    my $actual_value = $job->{settings}->{$key};
    return $actual_value && $actual_value eq $expected_value;
}

sub _get_chained_parents ($job, $url_handler, $options, $parents = [], $parent_ids = {}) {
    next if $parent_ids->{$job->{id}}++;
    my @direct_parents = map { clone_job_get_job($_, $url_handler, $options) } @{$job->{parents}->{Chained}};
    push @$parents, @direct_parents;
    _get_chained_parents($_, $url_handler, $options, $parents, $parent_ids) for @direct_parents;
    return $parents;
}

sub _is_asset_generated_by_cloned_jobs ($job, $parents, $file, $options) {
    return 0 if ($options->{'skip-deps'} || $options->{'skip-chained-deps'}) && (scalar @$parents != 0);
    for my $j (@$parents, $job) {
        for my $setting (qw(PUBLISH_HDD_1 PUBLISH_PFLASH_VARS)) {
            return 1 if _job_setting_is $j, $setting => $file;
        }
    }
    return 0;
}

sub _job_publishes_uefi_vars ($job, $file) {
    $job->{settings}->{UEFI} && _job_setting_is $job, PUBLISH_PFLASH_VARS => $file;
}

sub clone_job_download_assets ($jobid, $job, $url_handler, $options) {
    my $parents = _get_chained_parents($job, $url_handler, $options);
    my $ua = $url_handler->{ua};
    my $remote_url = $url_handler->{remote_url};
    for my $type (keys %{$job->{assets}}) {
        next if $type eq 'repo';    # we can't download repos
        for my $file (@{$job->{assets}->{$type}}) {
            my $dst = $file;
            # skip downloading published assets if we are also cloning the generation job or
            # if the only cloned job *is* the generation job
            next if _is_asset_generated_by_cloned_jobs $job, $parents, $file, $options;
            # skip downloading "uefi-vars" assets if not actually generated by
            # any parent
            if ($file =~ qr/uefi-vars/) {
                my $parent_publishes_uefi_vars;
                $parent_publishes_uefi_vars = _job_publishes_uefi_vars $_, $file and last for @$parents;
                next unless $parent_publishes_uefi_vars;
            }
            $dst =~ s,.*/,,;
            $dst = join('/', $options->{dir}, $type, $dst);
            my $from = $remote_url->clone;
            $from->path(sprintf '/tests/%d/asset/%s/%s', $jobid, $type, $file);
            $from = $from->to_string;

            die "can't write $options->{dir}/$type\n" unless -w "$options->{dir}/$type";

            print STDERR "downloading\n$from\nto\n$dst\n";
            my $r = $ua->mirror($from, $dst);
            unless ($r->is_success || $r->code == 304) {
                print STDERR "$jobid failed: $file, ", $r->status_line, "\n";
                die "Can't clone due to missing assets: ", $r->status_line, " \n"
                  unless $options->{'ignore-missing-assets'};
            }

            # ensure the asset cleanup preserves the asset the configured amount of days starting from the time
            # it has been cloned (otherwise old assets might be cleaned up directly again after cloning)
            path($dst)->touch;
        }
    }
}

sub split_jobid ($url_string) {
    my $url = Mojo::URL->new($url_string);

    # handle scheme being omitted and support specifying only a domain (e.g. 'openqa.opensuse.org')
    $url->scheme('http') unless $url->scheme;
    $url->host($url->path->parts->[0]) unless $url->host;

    my $host_url = Mojo::URL->new->scheme($url->scheme)->host($url->host)->port($url->port)->to_string;
    (my $jobid) = $url->path =~ /([0-9]+)/;
    return ($host_url, $jobid);
}

sub create_url_handler ($options) {
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    $ua->env_proxy;
    $ua->show_progress(1) if ($options->{'show-progress'});

    my $local_url = OpenQA::Client::url_from_host($options->{host});
    $local_url->path('/api/v1/jobs');
    my $local = OpenQA::Client->new(
        api => $local_url->host,
        apikey => $options->{'apikey'},
        apisecret => $options->{'apisecret'});
    die "API key/secret missing. Checkout '$0 --help' for the config file syntax/lookup.\n"
      unless $local->apikey && $local->apisecret;

    my $remote_url = OpenQA::Client::url_from_host($options->{from});
    $remote_url->path('/api/v1/jobs');
    my $remote = OpenQA::Client->new(api => $options->{host});

    return {ua => $ua, local => $local, local_url => $local_url, remote => $remote, remote_url => $remote_url};
}

sub openqa_baseurl ($local_url) {
    my $port = '';
    if (
        $local_url->port
        && (   ($local_url->scheme eq 'http' && $local_url->port != 80)
            || ($local_url->scheme eq 'https' && $local_url->port != 443)))
    {
        $port = ':' . $local_url->port;
    }
    return $local_url->scheme . '://' . $local_url->host . $port;
}

sub get_deps ($job, $options, $job_type) {
    my ($chained, $directly_chained, $parallel);
    unless ($job_type eq 'parents' && $options->{'skip-deps'}) {
        unless ($job_type eq 'parents' && $options->{'skip-chained-deps'}) {
            $chained = $job->{$job_type}->{Chained};
            $directly_chained = $job->{$job_type}->{'Directly chained'};
        }
        $parallel = $job->{$job_type}->{Parallel};
    }

    return ($chained // [], $directly_chained // [], $parallel // []);
}

sub handle_tx ($tx, $url_handler, $options, $jobs) {
    my $res = $tx->res;
    my $json = $res->json;
    if (!$tx->error && ref $json eq 'HASH' && ref $json->{ids} eq 'HASH') {
        my $cloned_jobs = $json->{ids};
        print Cpanel::JSON::XS->new->pretty->encode($cloned_jobs) and return $cloned_jobs if $options->{'json-output'};
        my $base_url = openqa_baseurl($url_handler->{local_url});
        for my $orig_job_id (keys %$cloned_jobs) {
            my $orig_job = $jobs->{$orig_job_id};
            my $cloned_job_id = $cloned_jobs->{$orig_job_id};
            print "Created job #$cloned_job_id: $orig_job->{name} -> $base_url/t$cloned_job_id\n";
        }
        return $cloned_jobs;
    }
    elsif (my $body = $res->body) {
        die 'Failed to create job, server replied: ', pp(ref $json ? $json : $body), "\n";
    }
    else {
        die "Failed to create job, empty response. Make sure your HTTP proxy is running, e.g. apache, nginx, etc.\n";
    }
}

sub clone_jobs ($jobid, $options) {
    my $url_handler = create_url_handler($options);
    clone_job($jobid, $url_handler, $options, my $post_params = {}, my $jobs = {});
    my $tx = post_jobs($post_params, $url_handler, $options);
    handle_tx($tx, $url_handler, $options, $jobs) if $tx;
}

sub clone_job ($jobid, $url_handler, $options, $post_params = {}, $jobs = {}, $depth = 1, $relation = '') {
    return $post_params if defined $post_params->{$jobid};

    my $job = $jobs->{$jobid} = clone_job_get_job($jobid, $url_handler, $options);

    my $settings = $post_params->{$jobid} = {%{$job->{settings}}};
    my $clone_children = $options->{'clone-children'};
    my $max_depth = $options->{'max-depth'} // 1;
    for my $job_type (qw(parents children)) {
        next unless $job->{$job_type};

        my ($chained, $directly_chained, $parallel) = get_deps($job, $options, $job_type);
        print STDERR "Cloning $job_type of $job->{name}\n" if @$chained || @$directly_chained || @$parallel;

        for my $dependencies ($chained, $directly_chained, $parallel) {
            if ($job_type eq 'children') {
                # constrain cloning children according to specified options
                next if $max_depth && $depth > $max_depth;
                next unless $clone_children || $dependencies == $parallel;
            }
            clone_job($_, $url_handler, $options, $post_params, $jobs, $depth + 1, $job_type) for @$dependencies;
        }
        if ($job_type ne 'children') {
            $settings->{_PARALLEL} = join(',', @$parallel) if @$parallel;
            $settings->{_START_AFTER} = join(',', @$chained) if @$chained;
            $settings->{_START_DIRECTLY_AFTER} = join(',', @$directly_chained) if @$directly_chained;
        }
    }
    $settings->{CLONED_FROM} = $url_handler->{remote_url}->clone->path("/tests/$jobid")->to_string;
    if (my $group_id = $job->{group_id}) { $settings->{_GROUP_ID} = $group_id }
    clone_job_apply_settings($options->{args}, $relation eq 'children' ? 0 : $depth, $settings, $options);
    OpenQA::Script::CloneJobSUSE::detect_maintenance_update($jobid, $url_handler, $settings);
    clone_job_download_assets($jobid, $job, $url_handler, $options) unless $options->{'skip-download'};
}

sub post_jobs ($post_params, $url_handler, $options) {
    my %composed_params = map {
        my $job_id = $_;
        my $params_for_job = $post_params->{$job_id};
        map { my $key = "$_:$job_id"; $key => $params_for_job->{$_} } keys %$params_for_job
    } keys %$post_params;
    $composed_params{is_clone_job} = 1;    # used to figure out if this is a clone operation
    my ($local, $local_url) = ($url_handler->{local}, $url_handler->{local_url}->clone);
    if ($options->{'export-command'}) {
        $local_url->path(Mojo::Path->new);
        print "openqa-cli api --host '$local_url' -X POST jobs ";
        say join(' ', map { "'$_=$composed_params{$_ }'" } sort keys %composed_params);
        return undef;
    }
    print STDERR Cpanel::JSON::XS->new->pretty->encode(\%composed_params) if $options->{verbose};
    return $local->max_redirects(3)->post($local_url, form => \%composed_params);
}

1;
