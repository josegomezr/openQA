# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg::Constants;

# Define worker commands; used to validate and differentiate commands
use constant {
    # EXIT CODES
    # stop the current job(s), do *not* upload logs and assets
    EXIT_SUCCESS => 0,
    EXIT_ERR_ANNOUNCE => 1,
    EXIT_ERR_WS => 2,

    # Websocket messages from Worker -> openQA
    WS_WORKER_COMMAND_QUIT => 'quit',
    WS_WORKER_COMMAND_REJECT_JOBS => 'rejected',
    WS_WORKER_COMMAND_ACCEPT_JOB => 'accepted',
    WS_WORKER_COMMAND_WORKER_STATUS => 'worker_status',

    # Websocket messages from openQA -> Worker
    WS_OPENQA_COMMAND_GRAB_JOB => 'grab_job',
    WS_OPENQA_COMMAND_INFO => 'info',

    # Websocket worker status
    WS_STATUS_CONNECTED => 'connected',
    WS_STATUS_FREE => 'free',
    WS_STATUS_ACCEPTING => 'accepting',
    WS_STATUS_WORKING => 'working',
    WS_STATUS_STOPPING => 'stopping',
    WS_STATUS_STOPPED => 'stopped',
    # not used yet
    WS_STATUS_DISABLED => 'disabled',
    WS_STATUS_FAILED => 'failed',
    WS_STATUS_BROKEN => 'broken',


    JOB_STATUS_SETUP => 'setup',
};

1;
