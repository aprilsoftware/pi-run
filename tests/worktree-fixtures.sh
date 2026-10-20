#!/usr/bin/env bash
# Shared managed-worktree test fixtures. This file is sourced, not executed.

register_worktree_repository_fixture() {
    local root="$1" home="$2" repository="$3"
    TEST_ROOT="${root}" TEST_HOME="${home}" TEST_REPOSITORY="${repository}" bash -ceu '
        fail() { echo "pi-run: $*" >&2; exit 1; }
        PI_RUN_HOME_RESOLVED="${TEST_HOME}"
        source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
        ensure_worktree_repository_record "${TEST_REPOSITORY}"
    '
}
