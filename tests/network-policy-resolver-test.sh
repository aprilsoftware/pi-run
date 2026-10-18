#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${ROOT}/docker/network-policy-resolver.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "network-policy-resolver-test: $*" >&2
    exit 1
}

PROFILE="${TMP}/profile"
mkdir -p "${PROFILE}"
printf '%s\n' '{"providers":[{"id":"openai-codex","baseUrls":["https://chatgpt.com/backend-api"]}]}' \
    > "${TMP}/metadata.json"
printf '%s\n' \
    '{"network":{"mode":"restricted","allowHosts":["github.com","api.github.com","github.com"]}}' \
    > "${PROFILE}/profile.json"
printf '%s\n' \
    '{"openai-codex":{"type":"oauth","access":"RESOLVER_SECRET_MUST_NOT_APPEAR"}}' \
    > "${PROFILE}/auth.json"
printf '%s\n' \
    '{"providers":{"custom":{"baseUrl":"https://inference.example.test/v1","models":[{"id":"text"},{"id":"vision","baseUrl":"https://vision.example.test/api"}]}}}' \
    > "${PROFILE}/models.json"
printf '%s\n' '{"defaultProvider":"custom","enabledModels":["openai-codex/*"]}' \
    > "${PROFILE}/settings.json"

run_resolver() {
    PI_RUN_PROVIDER_METADATA_FILE="${TMP}/metadata.json" node "${RESOLVER}" "${PROFILE}"
}

output="$(run_resolver)"
[[ "$(jq -c '.modelHosts' <<< "${output}")" == \
   '["api.openai.com","auth.openai.com","chatgpt.com","inference.example.test","pi.dev","vision.example.test"]' ]] \
    || fail "model hostname resolution was incorrect"
[[ "$(jq -c '.additionalHosts' <<< "${output}")" == '["api.github.com","github.com"]' ]] \
    || fail "additional hostname resolution was incorrect"
[[ "$(jq -r 'keys | sort | join(",")' <<< "${output}")" == \
   'additionalHosts,modelHosts,schemaVersion' ]] || fail "resolver emitted unexpected fields"
[[ "${output}" != *RESOLVER_SECRET_MUST_NOT_APPEAR* ]] || fail "resolver printed a credential"

expect_failure() {
    local expected="$1"
    set +e
    failure_output="$(run_resolver 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "resolver accepted invalid input: ${expected}"
    [[ "${failure_output}" == *"${expected}"* ]] || fail "resolver failure lacked diagnostic: ${expected}"
    [[ "${failure_output}" != *RESOLVER_SECRET_MUST_NOT_APPEAR* ]] || fail "resolver failure printed a credential"
}

for endpoint in 'http://inference.example.test/v1' \
    'https://inference.example.test:8443/v1' 'https://192.0.2.1/v1' \
    'https://user:password@inference.example.test/v1'; do
    printf '{"providers":{"custom":{"baseUrl":"%s"}}}\n' "${endpoint}" > "${PROFILE}/models.json"
    printf '%s\n' '{"defaultProvider":"custom"}' > "${PROFILE}/settings.json"
    printf '%s\n' '{}' > "${PROFILE}/auth.json"
    expect_failure 'invalid HTTPS provider endpoint in provider metadata'
    [[ "${failure_output}" != *"${endpoint}"* ]] || fail "resolver printed a rejected endpoint"
done

printf '%s\n' '{}' > "${PROFILE}/models.json"
printf '%s\n' '{}' > "${PROFILE}/settings.json"
printf '%s\n' '{"unknown":{"key":"RESOLVER_SECRET_MUST_NOT_APPEAR"}}' > "${PROFILE}/auth.json"
expect_failure 'could not resolve a configured model provider endpoint'
printf '%s\n' '{"openai-codex":"RESOLVER_SECRET_MUST_NOT_APPEAR"' > "${PROFILE}/auth.json"
expect_failure 'invalid JSON in profile configuration file: auth.json'
printf '%s\n' '{}' > "${PROFILE}/auth.json"
printf '%s\n' '{"network":{"mode":"restricted","allowHosts":["https://github.com"]}}' \
    > "${PROFILE}/profile.json"
expect_failure 'invalid allowHosts entry'
printf '%s\n' '{"network":{"mode":"host"}}' > "${PROFILE}/profile.json"
expect_failure 'profile network mode is not restricted'

echo "Network policy resolver tests passed"
