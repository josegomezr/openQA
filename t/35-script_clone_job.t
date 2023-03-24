# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '6';
use Mojo::Base -signatures;
use Test::Exception;
use Test::Output qw(combined_like output_from);
use Test::MockObject;
use Test::MockModule;
use OpenQA::Script::CloneJob;
use Mojo::JSON qw(decode_json);
use Mojo::URL;
use Mojo::File 'tempdir';
use Mojo::Transaction;

# define fake client
{
    package Test::FakeLWPUserAgentMirrorResult;
    use Mojo::Base -base, -signatures;
    has is_success => 1;
    has code => 304;
    has status_line => 'some status';
}
{
    package Test::FakeLWPUserAgent;
    use Mojo::Base -base, -signatures;
    has mirrored => sub { {} };
    has missing => 0;
    sub mirror ($self, $from, $dest) {
        my @res
          = ($self->missing || $from !~ qr{http://foo/tests/1/asset/iso/(foo|bar)\.iso})
          ? (is_success => 0, code => 404)
          : ();
        $self->mirrored->{$from} = $dest;
        Test::FakeLWPUserAgentMirrorResult->new(@res);
    }
}

my @argv = qw(WORKER_CLASS=local HDD_1=new.qcow2 HDDSIZEGB=40);
my %options = ('parental-inheritance' => '');
my %child_settings = (
    NAME => '00000810-sle-15-Installer-DVD-x86_64-Build665.2-hpc_test@64bit',
    TEST => 'hpc_test',
    HDD_1 => 'sle-15-x86_64-Build665.2-with-hpc.qcow2',
    HDDSIZEGB => 20,
    WORKER_CLASS => 'qemu_x86_64',
);
my %parent_settings = (
    NAME => '00000810-sle-15-Installer-DVD-x86_64-Build665.2-create_hpc@64bit',
    TEST => 'create_hpc',
    HDD_1 => 'sle-15-x86_64-Build665.2-with-hpc.qcow2',
    HDDSIZEGB => 20,
    WORKER_CLASS => 'qemu_x86_64',
);

subtest 'clone job apply settings tests' => sub {
    my %test_settings = %child_settings;
    $test_settings{HDD_1} = 'new.qcow2';
    $test_settings{HDDSIZEGB} = 40;
    $test_settings{WORKER_CLASS} = 'local';
    delete $test_settings{NAME};
    clone_job_apply_settings(\@argv, 1, \%child_settings, \%options);
    is_deeply(\%child_settings, \%test_settings, 'cloned child job with correct global setting and new settings');

    %test_settings = %parent_settings;
    $test_settings{WORKER_CLASS} = 'local';
    delete $test_settings{NAME};
    clone_job_apply_settings(\@argv, 2, \%parent_settings, \%options);
    is_deeply(\%parent_settings, \%test_settings, 'cloned parent job only take global setting');
};

subtest '_GROUP and _GROUP_ID override each other' => sub {
    my %settings = ();
    clone_job_apply_settings([qw(_GROUP=foo _GROUP_ID=bar)], 0, \%settings, \%options);
    is_deeply(\%settings, {_GROUP_ID => 'bar'}, '_GROUP_ID overrides _GROUP');
    %settings = ();
    clone_job_apply_settings([qw(_GROUP_ID=bar _GROUP=foo)], 0, \%settings, \%options);
    is_deeply(\%settings, {_GROUP => 'foo'}, '_GROUP overrides _GROUP_ID');
};

subtest 'delete empty setting' => sub {
    my %settings = ();
    clone_job_apply_settings([qw(ISO_1= ADDONS=)], 0, \%settings, \%options);
    is_deeply(\%settings, {}, 'all empty settings removed');
};

subtest 'asset download' => sub {
    my $temp_assetdir = tempdir;
    my $fake_ua = Test::FakeLWPUserAgent->new;
    my %url_handler = (remote_url => Mojo::URL->new('http://foo'), ua => $fake_ua);
    my %options = (dir => $temp_assetdir);
    my $job_id = 1;
    my %job = (
        id => $job_id,
        parents => {Chained => [2]},
        assets => {
            repo => 'supposed to be skipped',
            iso => [qw(foo.iso bar.iso)],
            # HDDs which are not downloaded because generated by (indirect) parent (which is cloned as well)
            hdd => [qw(some.qcow2 uefi-vars.qcow2 another.qcow2)],
        },
    );
    my $clone_mock = Test::MockModule->new('OpenQA::Script::CloneJob');
    $clone_mock->redefine(
        clone_job_get_job => sub ($job_id, $url_handler, $options) {
            return {id => 2, settings => {}, parents => {Chained => [3, 4]}} if $job_id eq 2;
            return {id => 3, settings => {PUBLISH_HDD_1 => 'some.qcow2'}} if $job_id eq 3;
            return {id => 4, settings => {UEFI => 1, PUBLISH_PFLASH_VARS => 'uefi-vars.qcow2'}} if $job_id eq 4;
            return {id => 5, settings => {UEFI => 0, PUBLISH_PFLASH_VARS => 'uefi-vars.qcow2'}} if $job_id eq 5;
            fail "clone_job_get_job called with unexpected job ID \"$job_id\"";    # uncoverable statement
        });
    my %expected_downloads = (
        "http://foo/tests/$job_id/asset/iso/foo.iso" => "$temp_assetdir/iso/foo.iso",
        "http://foo/tests/$job_id/asset/iso/bar.iso" => "$temp_assetdir/iso/bar.iso",
        "http://foo/tests/$job_id/asset/hdd/another.qcow2" => "$temp_assetdir/hdd/another.qcow2",
    );

    throws_ok { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) }
    qr/can't write $temp_assetdir/, 'error because folder does not exist';

    $temp_assetdir->child($_)->make_path for qw(iso hdd);
    $fake_ua->missing(1);
    throws_ok {
        combined_like { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) }
        qr/downloading.*foo.*to.*failed.*some status/s, 'download error logged';
    }
    qr/Can't clone due to missing assets: some status/, 'error if asset does not exist';

    $options{'ignore-missing-assets'} = 1;
    combined_like { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) }
    qr/downloading.*foo.*to.*failed.*some status.*downloading.*bar.*failed/s, 'download error logged but ignored';

    $fake_ua->mirrored({})->missing(0);
    combined_like { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) }
    qr{downloading.*http://.*foo.iso.*to.*foo.iso.*downloading.*http://.*bar.iso.*to.*bar.iso}s, 'download logged';
    is_deeply($fake_ua->mirrored, \%expected_downloads,
        'assets downloadeded except HDDs which are generated by parent job anyways')
      or diag explain $fake_ua->mirrored;
    ok(-f "$temp_assetdir/iso/foo.iso", 'foo touched');
    ok(-f "$temp_assetdir/iso/bar.iso", 'foo touched');

    $fake_ua->mirrored({});
    $options{'skip-deps'} = 1;
    $expected_downloads{"http://foo/tests/$job_id/asset/hdd/some.qcow2"} = "$temp_assetdir/hdd/some.qcow2";
    $expected_downloads{"http://foo/tests/$job_id/asset/hdd/uefi-vars.qcow2"} = "$temp_assetdir/hdd/uefi-vars.qcow2";
    combined_like { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) } qr/downloading/,
      'downloading logged (1)';
    is_deeply($fake_ua->mirrored, \%expected_downloads,
        'assets downloadeded including HDDs because we skip cloning the parent job')
      or diag explain $fake_ua->mirrored;

    $fake_ua->mirrored({});
    $job{parents} = {Chained => [3, 5]};
    delete $expected_downloads{"http://foo/tests/$job_id/asset/hdd/uefi-vars.qcow2"};
    combined_like { clone_job_download_assets($job_id, \%job, \%url_handler, \%options) } qr/downloading/,
      'downloading logged (2)';
    is_deeply($fake_ua->mirrored, \%expected_downloads,
        'assets downloadeded except uefi-vars because no parent produces it anyways')
      or diag explain $fake_ua->mirrored;
};

subtest 'get 2 nodes HA cluster with get_deps' => sub {
    my %node1_settings = (
        NAME => '00007936-sle-15-SP3-Online-x86_64-Build67.1-sles4sap_hana_node01@64bit-sap',
        TEST => 'sles4sap_hana_node01',
        HDD_1 => 'SLE-15-SP3-x86_64-Build67.1-sles4sap-gnome.qcow2',
        HDDSIZEGB => 60,
        PARALLEL_WITH => 'sles4sap_hana_supportserver@64bit-2gbram',
        NICTYPE => 'tap',
        WORKER_CLASS => 'tap,qemu_x86_64',
    );
    my %node2_settings = (
        NAME => '00007935-sle-15-SP3-Online-x86_64-Build67.1-sles4sap_hana_node02@64bit-sap',
        TEST => 'sles4sap_hana_node02',
        HDD_1 => 'SLE-15-SP3-x86_64-Build67.1-sles4sap-gnome.qcow2',
        HDDSIZEGB => 60,
        PARALLEL_WITH => 'sles4sap_hana_supportserver@64bit-2gbram',
        NICTYPE => 'tap',
        WORKER_CLASS => 'tap,qemu_x86_64',
    );
    my %supportserver_settings = (
        NAME => "00007934-sle-15-SP3-Online-x86_64-Build67.1-sles4sap_hana_supportserver@64bit-2gbram",
        TEST => 'sles4sap_hana_supportserver',
        HDD_1 => 'openqa_support_server_sles12sp3.x86_64.qcow2',
        HDDSIZEGB => 60,
        NICTYPE => 'tap',
        WORKER_CLASS => 'tap,qemu_x86_64',
    );
    my %node1_job = (
        settings => \%node1_settings,
        id => 7936,
        parents => {
            Parallel => [7934],
        },
    );
    my %node2_job = (
        settings => \%node2_settings,
        id => 7935,
        parents => {
            Parallel => [7934],
        },
    );
    my %supportserver_job = (
        settings => \%supportserver_settings,
        id => 7934,
        children => {
            Parallel => [7935, 7936],
        },
    );
    my ($chained, $directly_chained, $parallel) = OpenQA::Script::CloneJob::get_deps(\%supportserver_job, 'children');
    is_deeply($parallel, [7935, 7936], 'getting children nodes jobid from supportserver');
    ($chained, $directly_chained, $parallel) = OpenQA::Script::CloneJob::get_deps(\%node1_job, 'parents');
    is_deeply($parallel, [7934], 'getting supportserver jobid from node1');
    ($chained, $directly_chained, $parallel) = OpenQA::Script::CloneJob::get_deps(\%node2_job, 'parents');
    is_deeply($parallel, [7934], 'getting supportserver jobid from node2');
};

subtest 'error handling' => sub {
    my $tx = Mojo::Transaction->new;
    my %url_handler = (local_url => Mojo::URL->new('https://base-url/foo/bar'));
    my $test = sub { OpenQA::Script::CloneJob::handle_tx($tx, \%url_handler, {}, {42 => {name => 'testjob'}}) };
    throws_ok { $test->() } qr/Failed to create job, empty response/, 'empty response handled';
    $tx->res->body('foobar');
    throws_ok { $test->() } qr/Failed to create job, server replied: "foobar"/, 'unexpected non-JSON handled';
    $tx->res->code(200)->body('{"foo": "bar"}');
    throws_ok { $test->() } qr/Failed to create job, server replied: \{ foo => "bar" \}/, 'unexpected JSON handled';
    ($tx = Mojo::Transaction->new)->res->code(200)->body('{"ids": {"42": 43}}');
    combined_like { $test->() } qr|1 job has been created:.* - testjob -> https://base-url/tests/43|s,
      'expected response';
};

subtest 'export command' => sub {
    my %job_settings = (param => 'baz');
    my %options = (host => 'foo', from => 'bar', map { $_ => 1 } qw(apikey apisecret skip-download export-command));
    my $expected_params = "'CLONED_FROM:42=https://bar/tests/42' 'is_clone_job=1' 'param:42=baz'";
    my $expected_cmd = qr{openqa-cli api --host 'https://foo' -X POST jobs $expected_params};
    my $clone_mock = Test::MockModule->new('OpenQA::Script::CloneJob');
    $clone_mock->redefine(clone_job_get_job => sub ($job_id, @args) { {id => $job_id, settings => \%job_settings} });
    combined_like { clone_jobs(42, \%options) } $expected_cmd, 'openqa-cli command printed';
};

subtest 'overall cloning with parallel and chained dependencies' => sub {
    # do not actually post any jobs, assume jobs can be cloned (clone ID = original ID + 100)
    my $ua_mock = Test::MockModule->new('Mojo::UserAgent');
    my $clone_mock = Test::MockModule->new('OpenQA::Script::CloneJob');
    my @post_args;
    my $tx_handled = 0;
    $ua_mock->redefine(post => sub { push @post_args, [@_] });
    $clone_mock->redefine(handle_tx => sub ($tx, $url_handler, $options, $jobs) { $tx_handled = 1 });

    # fake the jobs to be cloned
    my %fake_jobs = (
        41 => {id => 41, name => 'parent', settings => {TEST => 'parent'}, children => {Parallel => [42]}},
        42 => {
            id => 42,
            name => 'main',
            settings => {TEST => 'main', group_id => 21},
            parents => {Parallel => [41]},
            children => {Chained => [43]}
        },
        43 => {id => 43, name => 'child', settings => {TEST => 'child'}, parents => {Chained => [42]}},
    );
    $clone_mock->redefine(clone_job_get_job => sub ($job_id, @args) { $fake_jobs{$job_id} });

    my %options
      = (host => 'foo', from => 'bar', 'clone-children' => 1, 'skip-download' => 1, verbose => 1, args => ['FOO=bar']);
    throws_ok { OpenQA::Script::CloneJob::clone_jobs(42, \%options) } qr|API key/secret missing|,
      'dies on missing API credentials';

    $options{apikey} = $options{apisecret} = 'bar';
    combined_like { OpenQA::Script::CloneJob::clone_jobs(42, \%options) } qr|parent.*main.*child|s,
      'verbose output printed';
    ok $tx_handled, 'transaction handled';

    my $check_common_post_args = sub ($test_suffix = '') {
        is scalar @post_args, 1, 'exactly one post call made' or return undef;
        my $params = $post_args[0]->[3] // {};
        is delete $params->{is_clone_job}, 1, 'is_clone_job-flag set';
        is delete $params->{'TEST:41'}, "parent$test_suffix", 'parent job 41 cloned';
        is delete $params->{'TEST:42'}, "main$test_suffix", 'main job 42 cloned';
        is delete $params->{'_PARALLEL:42'}, '41', 'main job cloned to start parallel with parent job 41';
        is delete $params->{'group_id:42'}, 21, 'group of 42 preserved';
        return $params;
    };
    subtest 'post args' => sub {
        my $params = $check_common_post_args->() or return;
        is delete $params->{'FOO:42'}, 'bar', 'setting passed to main job';
        is delete $params->{'TEST:43'}, 'child', 'child job 43 cloned';
        is delete $params->{'FOO:43'}, 'bar', 'setting passed to child job';
        is delete $params->{'_START_AFTER:43'}, '42', 'child job cloned to start after main job 42';
        is delete $params->{"CLONED_FROM:$_"}, "https://bar/tests/$_", "CLONED_FROM set ($_)" for 41, 42, 43;
        is scalar keys %$params, 0, 'exactly 3 jobs posted, so no further settings';
    } or diag explain \@post_args;

    subtest 'clone with parential inheritance' => sub {
        @post_args = ();
        $options{'clone-children'} = undef;
        $options{'parental-inheritance'} = 1;
        combined_like { OpenQA::Script::CloneJob::clone_jobs(42, \%options) } qr/cloning/i, 'output logged';
        subtest 'post args' => sub {
            my $params = $check_common_post_args->() or return;
            is delete $params->{'FOO:41'}, 'bar', 'setting passed to parent job';
            is delete $params->{'FOO:42'}, 'bar', 'setting passed to main job';
            is delete $params->{"CLONED_FROM:$_"}, "https://bar/tests/$_", "CLONED_FROM set ($_)" for 41, 42;
            is scalar keys %$params, 0, 'exactly 2 jobs posted, so no further settings';
        } or diag explain \@post_args;
    };

    subtest 'clone only parallel children, enable json output' => sub {
        # invoke handle_tx with fake data
        $clone_mock->redefine(
            handle_tx => sub (@) {
                my $res = Test::MockObject->new->set_always(json => {ids => {1 => 2}});
                my $tx = Test::MockObject->new->set_false('error')->set_always(res => $res);
                $clone_mock->original('handle_tx')->($tx, undef, \%options, undef);
            });

        @post_args = ();
        $fake_jobs{41}->{children}->{Chained} = [7];
        $options{'parental-inheritance'} = undef;
        $options{'json-output'} = 1;
        push @{$options{args}}, 'TEST+=:suffix';
        my ($stdout, $stderr) = output_from { OpenQA::Script::CloneJob::clone_jobs(41, \%options) };
        my $json_output = decode_json $stdout;
        like $stderr, qr/cloning/i, 'logs end up in stderr';
        is_deeply $json_output, {1 => 2}, 'fake response printed as JSON' or diag explain $json_output;
        subtest 'post args' => sub {
            my $params = $check_common_post_args->(':suffix') or return;
            is delete $params->{'FOO:41'}, 'bar', 'setting passed to main job';
            is delete $params->{'FOO:42'}, 'bar', 'setting passed to child job';
            is delete $params->{"CLONED_FROM:$_"}, "https://bar/tests/$_", "CLONED_FROM set ($_)" for 41, 42;
            is scalar keys %$params, 0, 'exactly 2 jobs posted, so no further settings';
        } or diag explain \@post_args;
    };

    subtest 'skip-deps affects only parents' => sub {
        @post_args = ();

        local $options{'clone-children'} = 1;
        local $options{'skip-deps'} = 1;

        combined_like { OpenQA::Script::CloneJob::clone_jobs(42, \%options) } qr/cloning/i, 'output logged';
        subtest 'post args' => sub {
            my $params = $post_args[0]->[3] // {};
            is $params->{'CLONED_FROM:42'}, 'https://bar/tests/42', 'main job has been cloned';
            is $params->{'CLONED_FROM:43'}, 'https://bar/tests/43', 'child job has been clones';
            is $params->{'_START_AFTER:43'}, '42', 'child job cloned to start after main job 42';
            ok !$params->{'CLONED_FROM:41'}, 'parent job has not been cloned';
        } or diag explain \@post_args;
    };

    subtest 'skip-chained-deps affects only parents' => sub {
        @post_args = ();

        # Replace parallel parent job with chained one for this test
        local $fake_jobs{41}
          = {id => 41, name => 'parent', settings => {TEST => 'parent'}, children => {Chained => [42]}};
        local $fake_jobs{42} = {
            id => 42,
            name => 'main',
            settings => {TEST => 'main', group_id => 21},
            parents => {Chained => [41]},
            children => {Chained => [43]}};

        local $options{'clone-children'} = 1;
        local $options{'skip-chained-deps'} = 1;

        combined_like { OpenQA::Script::CloneJob::clone_jobs(42, \%options) } qr/cloning/i, 'output logged';
        subtest 'post args' => sub {
            my $params = $post_args[0]->[3] // {};
            is $params->{'CLONED_FROM:42'}, 'https://bar/tests/42', 'main job has been cloned';
            is $params->{'CLONED_FROM:43'}, 'https://bar/tests/43', 'child job has been clones';
            ok !$params->{'CLONED_FROM:41'}, 'parent job has not been cloned';
        } or diag explain \@post_args;
    };
};

done_testing();
