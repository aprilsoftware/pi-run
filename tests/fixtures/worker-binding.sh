#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Disposable snapshot fixture; never a real Worker or execution authorization.
worker_binding_fixture() {
    local root="$1" reference=11111111-1111-4111-8111-111111111111
    local directory="${root}/worker-sessions/${reference}"
    mkdir -p "${directory}"
    chmod 0700 "${root}/worker-sessions" "${directory}"
    printf 'Snapshot fixture Role\n' > "${directory}/role.txt"
    jq -n --arg ref "${reference}" --arg role "$(sha256sum "${directory}/role.txt" | awk '{print $1}')" '
        {schemaVersion:1,reference:$ref,profile:"default",workspaceId:"22222222-2222-4222-8222-222222222222",
         roleHash:$role,configHash:("a" * 64),runtimeId:("sha256:" + ("b" * 64)),
         createdAt:"2026-11-26T00:00:00Z",sessionId:null,sessionFile:null}
    ' > "${directory}/binding.json"
    chmod 0600 "${directory}/role.txt" "${directory}/binding.json"
}
