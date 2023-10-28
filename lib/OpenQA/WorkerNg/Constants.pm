# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WorkerNg::Constants;

# Define worker commands; used to validate and differentiate commands
use constant {
    # stop the current job(s), do *not* upload logs and assets
    EXIT_SUCCESS => 0,
    EXIT_ERR_ANNOUNCE => 1,
    EXIT_ERR_WS => 2,
};


1;