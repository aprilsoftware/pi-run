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
SSH_DIR="${PROFILE}/credentials/ssh"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key() {
    ssh-keygen -q -t ed25519 -N "${2:-}" -f "${SSH_DIR}/$1"
}
make_key deploy@ssh.example.test
make_key deploy@192.0.2.44
sed -i 's/$/ SSH_PUBLIC_COMMENT_MUST_NOT_APPEAR/' "${SSH_DIR}/deploy@192.0.2.44.pub"
printf '%s\n' \
    '{"providers":[{"id":"openai-codex","baseUrls":["https://chatgpt.com/backend-api"]},{"id":"azure","baseUrls":[]},{"id":"google-vertex","baseUrls":["https://{location}-aiplatform.googleapis.com"]},{"id":"amazon-bedrock","baseUrls":["https://bedrock-runtime.us-east-1.amazonaws.com"]},{"id":"github-copilot","baseUrls":["https://api.individual.githubcopilot.com"]}]}' \
    > "${TMP}/metadata.json"
printf '%s\n' \
    '{"network":{"mode":"restricted","allow":[{"host":"git.example.test","tcpPorts":[443,22]},{"domain":"example.test"},{"cidr":"10.20.30.17/24","tcpPorts":[22]},{"cidr":"2001:0db8::1/64"},{"internet":true,"tcpPorts":[8443,443]}]}}' \
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
expected_model_hosts='["api.openai.com","auth.openai.com","chatgpt.com","inference.example.test","pi.dev","vision.example.test"]'
[[ "$(jq -c '[.modelRules[].host]' <<< "${output}")" == "${expected_model_hosts}" ]] \
    || fail "model rule resolution was incorrect"
jq -e 'all(.modelRules[]; .tcpPorts == [443] and (keys == ["host", "tcpPorts"]))' \
    <<< "${output}" >/dev/null || fail "model rules were not exact TCP/443 rules"
[[ "$(jq -c '.sshRules' <<< "${output}")" == \
   '[{"cidr":"192.0.2.44/32","tcpPorts":[22]},{"host":"ssh.example.test","tcpPorts":[22]}]' ]] \
    || fail "managed SSH rules were not inferred"
[[ "$(jq -c '.manualRules' <<< "${output}")" == \
   '[{"cidr":"10.20.30.0/24","tcpPorts":[22]},{"cidr":"2001:db8::/64"},{"domain":"example.test"},{"host":"git.example.test","tcpPorts":[22,443]},{"internet":true,"tcpPorts":[443,8443]}]' ]] \
    || fail "manual rule normalization was incorrect"
[[ "$(jq -r 'keys | sort | join(",")' <<< "${output}")" == \
   'manualRules,modelRules,schemaVersion,sshRules' ]] || fail "resolver emitted unexpected fields"
[[ "${output}" != *RESOLVER_SECRET_MUST_NOT_APPEAR* ]] || fail "resolver printed a credential"
[[ "${output}" != *SSH_PUBLIC_COMMENT_MUST_NOT_APPEAR* ]] || fail "resolver printed an SSH key comment"

expect_failure() {
    local expected="$1"
    set +e
    failure_output="$(run_resolver 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "resolver accepted invalid input: ${expected}"
    [[ "${failure_output}" == *"${expected}"* ]] || fail "resolver failure lacked diagnostic: ${expected}"
    [[ "${failure_output}" != *RESOLVER_SECRET_MUST_NOT_APPEAR* ]] || fail "resolver failure printed a secret"
    [[ "${failure_output}" != *SSH_PUBLIC_COMMENT_MUST_NOT_APPEAR* ]] \
        || fail "resolver failure printed an SSH key comment"
}

rm "${SSH_DIR}/deploy@ssh.example.test.pub"
expect_failure 'incomplete managed SSH credential pair'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key deploy@ssh.example.test secret
expect_failure 'invalid or encrypted managed SSH private key'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key deploy@ssh.example.test
ssh-keygen -q -t ed25519 -N '' -f "${TMP}/other-ssh-key"
cp "${TMP}/other-ssh-key.pub" "${SSH_DIR}/deploy@ssh.example.test.pub"
expect_failure 'mismatched managed SSH credential pair'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
ln -s /dev/null "${SSH_DIR}/deploy@ssh.example.test"
printf '%s\n' 'ssh-ed25519 AAAA' > "${SSH_DIR}/deploy@ssh.example.test.pub"
expect_failure 'unsafe managed SSH credential entry'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key deploy@same.example.test
make_key admin@same.example.test
expect_failure 'ambiguous managed SSH credential hostname'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key deploy@single
expect_failure 'invalid managed SSH credential target'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"
make_key deploy@ssh.example.test
chmod 0644 "${SSH_DIR}/deploy@ssh.example.test"
expect_failure 'unsafe managed SSH private key permissions'
rm -rf "${PROFILE}/credentials"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}/credentials" "${SSH_DIR}"

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

printf '%s\n' '{"defaultProvider":"azure"}' > "${PROFILE}/settings.json"
expect_failure 'provider azure requires an explicit HTTPS baseUrl in models.json for restricted networking'
printf '%s\n' '{"providers":{"azure":{"baseUrl":"https://azure-endpoint.example.test/openai/v1"}}}' \
    > "${PROFILE}/models.json"
[[ "$(run_resolver | jq -r '.modelRules[].host' | grep -Fxc azure-endpoint.example.test)" -eq 1 ]] \
    || fail "explicit Azure endpoint was not accepted"

printf '%s\n' '{}' > "${PROFILE}/models.json"
printf '%s\n' '{"defaultProvider":"google-vertex"}' > "${PROFILE}/settings.json"
expect_failure 'provider google-vertex requires an explicit HTTPS baseUrl in models.json for restricted networking'
printf '%s\n' '{"providers":{"google-vertex":{"baseUrl":"https://vertex-endpoint.example.test/v1"}}}' \
    > "${PROFILE}/models.json"
[[ "$(run_resolver | jq -r '.modelRules[].host' | grep -Fxc vertex-endpoint.example.test)" -eq 1 ]] \
    || fail "explicit Vertex endpoint was not accepted"

printf '%s\n' '{}' > "${PROFILE}/models.json"
printf '%s\n' '{"defaultProvider":"github-copilot"}' > "${PROFILE}/settings.json"
printf '%s\n' \
    '{"github-copilot":{"type":"oauth","access":"RESOLVER_SECRET_MUST_NOT_APPEAR","enterpriseUrl":"private-enterprise.example.test"}}' \
    > "${PROFILE}/auth.json"
expect_failure 'provider github-copilot uses a credential-derived endpoint unsupported by restricted networking'
[[ "${failure_output}" != *private-enterprise.example.test* ]] \
    || fail "resolver printed a private Copilot enterprise domain"
printf '%s\n' \
    '{"github-copilot":{"type":"oauth","access":"RESOLVER_SECRET_MUST_NOT_APPEAR;proxy-ep=proxy.private-copilot.example.test;"}}' \
    > "${PROFILE}/auth.json"
expect_failure 'provider github-copilot uses a credential-derived endpoint unsupported by restricted networking'
[[ "${failure_output}" != *private-copilot.example.test* ]] \
    || fail "resolver printed a Copilot token-derived domain"
printf '%s\n' \
    '{"github-copilot":{"type":"oauth","access":"RESOLVER_SECRET_MUST_NOT_APPEAR;proxy-ep=proxy.individual.githubcopilot.com;"}}' \
    > "${PROFILE}/auth.json"
expected_copilot_hosts='["api.github.com","api.individual.githubcopilot.com","github.com","pi.dev"]'
[[ "$(run_resolver | jq -c '[.modelRules[].host]')" == "${expected_copilot_hosts}" ]] \
    || fail "personal Copilot policy omitted a deterministic endpoint"

printf '%s\n' '{}' > "${PROFILE}/models.json"
printf '%s\n' '{"defaultProvider":"amazon-bedrock"}' > "${PROFILE}/settings.json"
printf '%s\n' \
    '{"amazon-bedrock":{"type":"api_key","key":"RESOLVER_SECRET_MUST_NOT_APPEAR","env":{"AWS_REGION":"private-region-value"}}}' \
    > "${PROFILE}/auth.json"
expect_failure 'provider amazon-bedrock uses a region-derived endpoint unsupported by restricted networking'
[[ "${failure_output}" != *private-region-value* ]] || fail "resolver printed a Bedrock region value"

printf '%s\n' '{}' > "${PROFILE}/auth.json"
printf '%s\n' \
    '{"providers":{"amazon-bedrock":{"models":[{"id":"arn:aws:bedrock:us-west-2:123456789012:inference-profile/private","baseUrl":"https://bedrock-endpoint.example.test"}]}}}' \
    > "${PROFILE}/models.json"
expect_failure 'provider amazon-bedrock uses a region-derived endpoint unsupported by restricted networking'
[[ "${failure_output}" != *123456789012* ]] || fail "resolver printed a Bedrock account ID"

printf '%s\n' '{}' > "${PROFILE}/models.json"
printf '%s\n' '{}' > "${PROFILE}/settings.json"
printf '%s\n' '{}' > "${PROFILE}/auth.json"
printf '%s\n' '{"network":{"mode":"restricted"}}' > "${PROFILE}/profile.json"
make_key deploy@ssh-only.example.test
[[ "$(run_resolver | jq -c '{modelRules,sshRules,manualRules}')" == \
   '{"modelRules":[],"sshRules":[{"host":"ssh-only.example.test","tcpPorts":[22]}],"manualRules":[]}' ]] \
    || fail "SSH-only restricted policy was not accepted"
rm -rf "${PROFILE}/credentials"
printf '%s\n' '{"network":{"mode":"restricted","allow":[{"internet":true}]}}' \
    > "${PROFILE}/profile.json"
[[ "$(run_resolver | jq -c '.manualRules')" == '[{"internet":true}]' ]] \
    || fail "all-TCP public internet rule was not accepted"
while IFS=$'\t' read -r expected network; do
    printf '{"network":%s}\n' "${network}" > "${PROFILE}/profile.json"
    expect_failure "${expected}"
done <<'EOF'
invalid network configuration in profile.json	{"mode":"restricted","extra":true}
invalid allow rules in profile.json	{"mode":"restricted","allow":{}}
invalid manual network rule	{"mode":"restricted","allow":[{"host":"one.test","domain":"two.test"}]}
invalid manual network rule	{"mode":"restricted","allow":[{"host":"one.test","internet":true}]}
invalid internet rule	{"mode":"restricted","allow":[{"internet":false}]}
multiple internet rules are not allowed	{"mode":"restricted","allow":[{"internet":true},{"internet":true,"tcpPorts":[443]}]}
invalid domain rule	{"mode":"restricted","allow":[{"domain":"*.example.test"}]}
invalid tcpPorts in manual network rule	{"mode":"restricted","allow":[{"host":"one.test","tcpPorts":[22,22]}]}
invalid tcpPorts in manual network rule	{"mode":"restricted","allow":[{"cidr":"10.0.0.0/8","tcpPorts":[0]}]}
invalid CIDR rule	{"mode":"restricted","allow":[{"cidr":"10.0.0.0/99"}]}
CIDR rule overlaps a blocked range	{"mode":"restricted","allow":[{"cidr":"127.0.0.1/32"}]}
duplicate manual network rule	{"mode":"restricted","allow":[{"host":"one.test","tcpPorts":[443,22]},{"host":"one.test","tcpPorts":[22,443]}]}
EOF

printf '%s\n' '{"network":{"mode":"host"}}' > "${PROFILE}/profile.json"
expect_failure 'profile network mode is not restricted'

echo "Network policy resolver tests passed"
