#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "component-layout-test: $*" >&2
    exit 1
}

SPDX='# SPDX-License-Identifier: MIT'
[[ "$(sed -n '2p' "${ROOT}/install.sh")" == "${SPDX}" ]] \
    || fail "standalone installer has no SPDX license identifier"
[[ "$(sed -n '1p' "${ROOT}/docker/Dockerfile")" == "${SPDX}" ]] \
    || fail "Dockerfile has no SPDX license identifier"
CORE_DOCKERFILE="${ROOT}/docker/core/Dockerfile"
[[ -f "${CORE_DOCKERFILE}" && ! -L "${CORE_DOCKERFILE}" &&
   "$(stat -c %a "${CORE_DOCKERFILE}")" == 644 ]] \
    || fail "core Dockerfile is missing or unsafe"
[[ "$(sed -n '1p' "${CORE_DOCKERFILE}")" == "${SPDX}" ]] \
    || fail "core Dockerfile has no SPDX license identifier"
grep -Fx 'FROM node:24-trixie-slim' "${CORE_DOCKERFILE}" >/dev/null \
    || fail "core Dockerfile does not use the slim Node 24 base"
for version in \
    'ARG PI_VERSION=1.5.2' \
    'ARG PI_WEB_ACCESS_VERSION=0.47.0' \
    'ARG PI_OKF_VERSION=0.4.0' \
    'ARG RESTIC_VERSION=0.19.1'; do
    grep -Fx "${version}" "${CORE_DOCKERFILE}" >/dev/null \
        || fail "core Dockerfile does not pin ${version#ARG }"
done
grep -Fx 'FROM debian:trixie-slim AS restic-downloader' "${CORE_DOCKERFILE}" >/dev/null \
    || fail "core Dockerfile has no build-only Restic stage"
grep -F "echo \"\${RESTIC_LINUX_AMD64_SHA256}  /tmp/restic.bz2\" | sha256sum -c -" \
    "${CORE_DOCKERFILE}" >/dev/null \
    || fail "core Dockerfile does not verify the Restic download"
for package in bash ca-certificates curl git gosu jq netcat-openbsd openssh-client openssl passwd ripgrep; do
    grep -Fx "        ${package} \\" "${CORE_DOCKERFILE}" >/dev/null \
        || fail "core Dockerfile does not install required package: ${package}"
done
for package in ansible build-essential clang cmake default-mysql-client gdb libasound2-dev \
    libgtk-3-dev maven openjdk-21-jdk-headless postgresql-client python3 python3-dev \
    redis-tools sqlite3; do
    if grep -Fx "        ${package} \\" "${CORE_DOCKERFILE}" >/dev/null; then
        fail "core Dockerfile installs optional package: ${package}"
    fi
done
for optional in 'ARG FLUTTER_VERSION=' 'ARG RUST_VERSION=' 'COPY --from=rust-toolchain' \
    'flutter_linux_' '/usr/local/bin/kubectl'; do
    if grep -F "${optional}" "${CORE_DOCKERFILE}" >/dev/null; then
        fail "core Dockerfile contains optional toolchain content: ${optional}"
    fi
done
for package in \
    "\"@earendil-works/pi-coding-agent@\${PI_VERSION}\"" \
    "\"pi-web-access@\${PI_WEB_ACCESS_VERSION}\"" \
    "\"pi-okf@\${PI_OKF_VERSION}\""; do
    grep -F "${package}" "${CORE_DOCKERFILE}" >/dev/null \
        || fail "core Dockerfile does not install required Pi package: ${package}"
done
broad_extension_copies="$(grep '^COPY extensions/' "${ROOT}/docker/Dockerfile")"
core_extension_copies="$(grep '^COPY extensions/' "${CORE_DOCKERFILE}")"
[[ "${core_extension_copies}" == "${broad_extension_copies}" ]] \
    || fail "core and broad Dockerfiles do not install the same extension bundle"
grep -Fx 'COPY skills/ /usr/local/share/pi-run/skills/' "${CORE_DOCKERFILE}" >/dev/null \
    || fail "core Dockerfile does not install core skills"
for component_copy in \
    'COPY entrypoint.sh ssh-credentials /usr/local/bin/' \
    'COPY java-trust-store.sh /usr/local/bin/pi-run-java-trust-store' \
    'COPY PiRunJavaTrustStore.java /usr/local/lib/pi-run/PiRunJavaTrustStore.java' \
    'COPY network-policy-resolver.mjs /usr/local/bin/pi-run-network-policy-resolver'; do
    grep -Fx "${component_copy}" "${CORE_DOCKERFILE}" >/dev/null \
        || fail "core Dockerfile omits runtime component: ${component_copy}"
done
grep -Fx 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh", "pi"]' "${CORE_DOCKERFILE}" >/dev/null \
    || fail "core Dockerfile does not preserve the runtime entrypoint contract"

FULL_RUNTIME_TEMPLATE="${ROOT}/templates/runtime/full-development.Dockerfile"
BASE_RUNTIME_TEMPLATE="${ROOT}/templates/runtime/Dockerfile"
[[ -f "${FULL_RUNTIME_TEMPLATE}" && ! -L "${FULL_RUNTIME_TEMPLATE}" &&
   "$(stat -c %a "${FULL_RUNTIME_TEMPLATE}")" == 644 ]] \
    || fail "full-development runtime template is missing or unsafe"
base_line_count="$(wc -l < "${BASE_RUNTIME_TEMPLATE}")"
cmp "${BASE_RUNTIME_TEMPLATE}" <(head -n "${base_line_count}" "${FULL_RUNTIME_TEMPLATE}") \
    || fail "full-development runtime does not start with the base runtime definition"
all_bundle_order="$(ROOT="${ROOT}" bash -c \
    'source "${ROOT}/lib/pi-run/runtimes.sh"; runtime_catalog_entries' | \
    awk -F '\t' '$1 == "group" && $2 == "all" { print $3 }' | tr ',' '\n')"
begin_bundle_order="$(sed -n 's/^# BEGIN PI-RUN BUNDLE //p' "${FULL_RUNTIME_TEMPLATE}")"
end_bundle_order="$(sed -n 's/^# END PI-RUN BUNDLE //p' "${FULL_RUNTIME_TEMPLATE}")"
[[ -n "${all_bundle_order}" && "${begin_bundle_order}" == "${all_bundle_order}" ]] \
    || fail "full-development bundle order differs from the all catalog"
[[ "${end_bundle_order}" == "${all_bundle_order}" ]] \
    || fail "full-development bundle endings are missing or unordered"
[[ "$(printf '%s\n' "${begin_bundle_order}" | sort -u | wc -l)" == \
   "$(printf '%s\n' "${begin_bundle_order}" | wc -l)" ]] \
    || fail "full-development runtime contains duplicate bundle blocks"
while IFS= read -r bundle; do
    awk -v begin="# BEGIN PI-RUN BUNDLE ${bundle}" \
        -v end="# END PI-RUN BUNDLE ${bundle}" '
        $0 == begin { inside = 1; next }
        $0 == end { exit(found ? 0 : 1) }
        inside && $0 ~ /^(ARG|COPY|ENV|RUN|USER) / { found = 1 }
        END { if (inside && !found) exit 1 }
    ' "${FULL_RUNTIME_TEMPLATE}" \
        || fail "full-development bundle is empty: ${bundle}"
done <<<"${all_bundle_order}"
for version in \
    'ARG RUST_VERSION=1.99.1' \
    'ARG FLUTTER_VERSION=3.47.2' \
    'ARG KUBECTL_VERSION=1.37.0' \
    'ARG HELM_VERSION=4.2.0' \
    'ARG KUSTOMIZE_VERSION=5.8.1' \
    'ARG YQ_VERSION=4.53.3'; do
    grep -Fx "${version}" "${FULL_RUNTIME_TEMPLATE}" >/dev/null \
        || fail "full-development runtime does not pin ${version#ARG }"
done
for capability in \
    'COPY --from=rust:1.99.1-trixie /usr/local/cargo /usr/local/cargo' \
    "openjdk-21-jdk-headless \\" \
    "flutter_linux_\${FLUTTER_VERSION}-stable.tar.xz" \
    "libxkbcommon-x11-0 \\" \
    "postgresql-client \\" \
    "kustomize_v\${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"; do
    grep -F "${capability}" "${FULL_RUNTIME_TEMPLATE}" >/dev/null \
        || fail "full-development runtime omits capability: ${capability}"
done
while IFS= read -r package; do
    if ! grep -Fx "        ${package} \\" "${CORE_DOCKERFILE}" >/dev/null \
        && ! grep -Fx "        ${package} \\" "${FULL_RUNTIME_TEMPLATE}" >/dev/null; then
        fail "core plus full-development templates omit broad package: ${package}"
    fi
done < <(awk '
    /^RUN apt-get update \\/ && !inside { inside = 1; next }
    inside && /&& rm -rf \/var\/lib\/apt\/lists/ { exit }
    inside && $1 ~ /^[a-z0-9]/ { print $1 }
' "${ROOT}/docker/Dockerfile")
[[ "$(sed -n '1p' "${ROOT}/docker/egress/Dockerfile")" == "${SPDX}" ]] \
    || fail "egress Dockerfile has no SPDX license identifier"
grep -Fx 'ARG RUST_VERSION=1.99.1' "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not pin Rust 1.99.1"
grep -Fx "FROM rust:\${RUST_VERSION}-trixie AS rust-toolchain" \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not use the versioned official Rust toolchain stage"
grep -Fx "RUN rustup component add --toolchain \"\${RUST_VERSION}\" rustfmt clippy \\" \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not install Rustfmt and Clippy with Rustup"
grep -Fx "RUN chmod -R a+w \"\${RUSTUP_HOME}\" \"\${CARGO_HOME}\"" \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not make copied Rustup directories writable"
for directory in cargo rustup; do
    grep -Fx "COPY --from=rust-toolchain /usr/local/${directory} /usr/local/${directory}" \
        "${ROOT}/docker/Dockerfile" >/dev/null \
        || fail "runtime image does not copy the Rustup-managed ${directory} directory"
done
for package in rustc cargo rustfmt rust-clippy; do
    if grep -Fx "        ${package} \\" "${ROOT}/docker/Dockerfile" >/dev/null; then
        fail "runtime image still installs Debian's ${package} package"
    fi
done
grep -Fx "        libasound2-dev \\" "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not install ALSA development headers"
grep -Fx "    pkg-config --modversion alsa; \\" "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not validate ALSA pkg-config metadata"
for package in libgl1-mesa-dri mesa-vulkan-drivers libxcb-xkb1 libxkbcommon-x11-0 xauth xvfb; do
    grep -Fx "        ${package} \\" "${ROOT}/docker/Dockerfile" >/dev/null \
        || fail "runtime image does not install GUI test package: ${package}"
done
for validation in \
    'xvfb-run --server-args="-screen 0 1280x720x24 -nolisten tcp" true' \
    '/usr/share/vulkan/icd.d' \
    "*/dri/*_dri.so" \
    "libxcb-xkb.so.1" \
    "libxkbcommon-x11.so.0"; do
    grep -F "${validation}" "${ROOT}/docker/Dockerfile" >/dev/null \
        || fail "runtime image does not validate GUI support: ${validation}"
done
[[ "$(sed -n '2p' "${ROOT}/docker/network-policy-resolver.mjs")" == "//${SPDX#\#}" ]] \
    || fail "network policy resolver has no SPDX license identifier"
[[ "$(sed -n '2p' "${ROOT}/docker/egress/entrypoint.sh")" == "${SPDX}" ]] \
    || fail "egress entrypoint has no SPDX license identifier"
[[ "$(sed -n '1p' "${ROOT}/.github/workflows/release.yml")" == "${SPDX}" ]] \
    || fail "release workflow has no SPDX license identifier"
[[ "$(sed -n '2p' "${BASH_SOURCE[0]}")" == "${SPDX}" ]] \
    || fail "packaging test has no SPDX license identifier"
expected_extension_layout="$(printf '%s\n' \
    cache/cache-policy-agent.ts \
    caf/caf-agent.ts \
    caf/caf-log-viewer.ts \
    caf/caf-protocol.ts \
    guard/guard-evidence.ts \
    guard/guard-journal.ts \
    guard/guard-reviewer-agent.ts \
    guard/guard-runtime-contract.ts \
    guard/guard-runtime.ts \
    guard/guard-viewer.ts \
    guardian/guardian-agent.ts \
    guardian/guardian-log-safety.ts \
    guardian/guardian-log-viewer.ts \
    guardian/guardian-review-trace.ts \
    guardian/guardian-reviewer.ts \
    plan/plan-agent.ts \
    snapshot/snapshot-agent.ts \
    title/title-agent.ts \
    todo/todo-agent.ts | LC_ALL=C sort)"
actual_extension_layout="$(find "${ROOT}/docker/extensions" -mindepth 1 \( -type f -o -type l \) \
    -printf '%P\n' | LC_ALL=C sort)"
[[ "${actual_extension_layout}" == "${expected_extension_layout}" ]] \
    || fail "runtime extension source layout differs from the architectural boundary"
while IFS= read -r extension; do
    path="${ROOT}/docker/extensions/${extension}"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe runtime extension source: ${extension}"
done <<<"${expected_extension_layout}"
image_license="${ROOT}/docker/licenses/pi-run-LICENSE"
[[ -f "${image_license}" && ! -L "${image_license}" ]] \
    || fail "runtime image license is missing or unsafe"
cmp -s "${ROOT}/LICENSE" "${image_license}" \
    || fail "runtime image license differs from the repository license"
grep -Fx 'COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE' \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "Dockerfile does not install the Pi-Run license"
grep -Fx 'COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE' \
    "${ROOT}/docker/egress/Dockerfile" >/dev/null \
    || fail "egress Dockerfile does not install the Pi-Run license"
grep -Fx 'COPY network-policy-resolver.mjs /usr/local/bin/pi-run-network-policy-resolver' \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not install the network policy resolver"
grep -Fx 'COPY PiRunJavaTrustStore.java /usr/local/lib/pi-run/PiRunJavaTrustStore.java' \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not install the Java host-CA source helper"
for runtime_dockerfile in "${ROOT}/docker/Dockerfile" "${CORE_DOCKERFILE}"; do
    grep -Fx 'COPY entrypoint.sh ssh-credentials /usr/local/bin/' \
        "${runtime_dockerfile}" >/dev/null \
        || fail "runtime image does not install its startup scripts"
    grep -Fx 'COPY java-trust-store.sh /usr/local/bin/pi-run-java-trust-store' \
        "${runtime_dockerfile}" >/dev/null \
        || fail "runtime image does not install Java trust setup at its invoked path"
done
if grep -F 'javac -d /usr/local/lib/pi-run' "${ROOT}/docker/Dockerfile" >/dev/null; then
    fail "runtime image still requires Java to compile the host-CA helper"
fi
[[ -f "${ROOT}/docker/PiRunJavaTrustStore.java" && \
   ! -L "${ROOT}/docker/PiRunJavaTrustStore.java" ]] \
    || fail "Java host-CA source helper is missing or unsafe"
[[ "$(sed -n '1p' "${ROOT}/docker/PiRunJavaTrustStore.java")" == "//${SPDX#\#}" ]] \
    || fail "Java host-CA source helper has no SPDX license identifier"
[[ -x "${ROOT}/docker/java-trust-store.sh" && \
   ! -L "${ROOT}/docker/java-trust-store.sh" ]] \
    || fail "Java trust setup helper is missing or unsafe"
[[ "$(sed -n '2p' "${ROOT}/docker/java-trust-store.sh")" == "${SPDX}" ]] \
    || fail "Java trust setup helper has no SPDX license identifier"
grep -F "/usr/local/bin/pi-run-java-trust-store \\" "${ROOT}/docker/entrypoint.sh" >/dev/null \
    || fail "runtime entrypoint does not dispatch capability-aware Java trust setup"
[[ -f "${ROOT}/docker/network-policy-resolver.mjs" && \
   ! -L "${ROOT}/docker/network-policy-resolver.mjs" ]] \
    || fail "network policy resolver is missing or unsafe"
[[ -x "${ROOT}/docker/egress/entrypoint.sh" && ! -L "${ROOT}/docker/egress/entrypoint.sh" ]] \
    || fail "egress entrypoint is missing or unsafe"
[[ ! -e "${ROOT}/experiments/docker-egress-tcp-rules" &&
   ! -L "${ROOT}/experiments/docker-egress-tcp-rules" ]] \
    || fail "promoted TCP egress implementation remains duplicated under experiments"
[[ ! -e "${ROOT}/experiments/docker-egress" &&
   ! -L "${ROOT}/experiments/docker-egress" ]] \
    || fail "promoted egress implementation remains duplicated under experiments"
[[ ! -e "${ROOT}/experiments/docker-git-worktree" &&
   ! -L "${ROOT}/experiments/docker-git-worktree" ]] \
    || fail "promoted managed-worktree implementation remains duplicated under experiments"
[[ -x "${ROOT}/tests/runtime-images-e2e-test.sh" &&
   ! -L "${ROOT}/tests/runtime-images-e2e-test.sh" ]] \
    || fail "runtime image real-Docker acceptance test is missing or unsafe"
[[ "$(sed -n '2p' "${ROOT}/tests/runtime-images-e2e-test.sh")" == "${SPDX}" ]] \
    || fail "runtime image real-Docker acceptance test has no SPDX identifier"
for required_runtime_acceptance_text in \
    'docker/core/Dockerfile' \
    'templates/runtime/full-development.Dockerfile' \
    'runtime add all' \
    'runtime build' \
    'runtime status' \
    '--network none'; do
    grep -F -- "${required_runtime_acceptance_text}" \
        "${ROOT}/tests/runtime-images-e2e-test.sh" >/dev/null \
        || fail "runtime image acceptance omits: ${required_runtime_acceptance_text}"
done
if grep -E 'docker (system|builder) prune' "${ROOT}/tests/runtime-images-e2e-test.sh" >/dev/null; then
    fail "runtime image acceptance prunes shared Docker state"
fi
for herdr_test in \
    herdr-wrapper-compatibility-test.sh \
    herdr-pi-run-launcher-test.sh \
    herdr-real-docker-test.sh; do
    [[ -x "${ROOT}/tests/${herdr_test}" && ! -L "${ROOT}/tests/${herdr_test}" ]] \
        || fail "Herdr acceptance test is missing or unsafe: ${herdr_test}"
    [[ "$(sed -n '2p' "${ROOT}/tests/${herdr_test}")" == "${SPDX}" ]] \
        || fail "Herdr acceptance test has no SPDX identifier: ${herdr_test}"
done
[[ -x "${ROOT}/tests/docker-egress-rules-e2e-test.sh" &&
   ! -L "${ROOT}/tests/docker-egress-rules-e2e-test.sh" ]] \
    || fail "production egress real-Docker test is missing or unsafe"
[[ -f "${ROOT}/tests/fixtures/docker-egress-rules-workload/Dockerfile" &&
   ! -L "${ROOT}/tests/fixtures/docker-egress-rules-workload/Dockerfile" ]] \
    || fail "production egress workload fixture is missing or unsafe"
grep -F "\"\${ROOT}/docker/egress/Dockerfile\"" \
    "${ROOT}/tests/docker-egress-rules-e2e-test.sh" >/dev/null \
    || fail "real-Docker egress test does not build the production implementation"
for package in iproute2 jq; do
    grep -Fx "        ${package} \\" "${ROOT}/docker/egress/Dockerfile" >/dev/null \
        || fail "egress Dockerfile does not install ${package}"
done
grep -Fx '  RUNTIME_IMAGE_NAME: ghcr.io/aprilsoftware/pi-run' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow has no versioned runtime image name"
grep -Fx "            --file docker/core/Dockerfile \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not build the profile-runtime core image"
grep -Fx '  EGRESS_IMAGE_NAME: ghcr.io/aprilsoftware/pi-run-egress' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow has no versioned egress image name"
grep -Fx "            --tag \"\${RUNTIME_IMAGE_NAME}:\${PI_RUN_VERSION}\" \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not version the runtime image"
grep -Fx "            --file docker/egress/Dockerfile \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not build the egress Dockerfile"
grep -Fx "            --tag \"\${EGRESS_IMAGE_NAME}:\${PI_RUN_VERSION}\" \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not version the egress image"
grep -Fx "          for image in \"\${RUNTIME_IMAGE_NAME}\" \"\${EGRESS_IMAGE_NAME}\"; do" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not push both images"
if grep -E -- '--tag .*:latest|docker push .*:latest' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null; then
    fail "release workflow publishes a mutable latest image"
fi
grep -Fx "            \"LICENSE\" \\" "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not publish the license"

EXPECTED="$(printf '%s\n' \
    doctor.sh profiles.sh restore.sh runtimes.sh sessions.sh skills.sh snapshots.sh \
    upgrade.sh workspaces.sh | LC_ALL=C sort)"

assert_component_set() {
    local label="$1" actual="$2"
    if [[ "${actual}" != "${EXPECTED}" ]]; then
        printf 'component-layout-test: %s component set differs\nexpected:\n%s\nactual:\n%s\n' \
            "${label}" "${EXPECTED}" "${actual}" >&2
        exit 1
    fi
}

actual="$(find "${ROOT}/lib/pi-run" -mindepth 1 -maxdepth 1 -type f -name '*.sh' \
    -printf '%f\n' | LC_ALL=C sort)"
assert_component_set "source tree" "${actual}"

actual="$(awk -F/ '
    /^validate_component "\$\{PI_RUN_LIB_ROOT\}\// {
        name=$NF; gsub(/"/, "", name); print name
    }
' "${ROOT}/bin/pi-run" | LC_ALL=C sort)"
assert_component_set "launcher validation" "${actual}"

actual="$(awk -F/ '
    /^source "\$\{PI_RUN_LIB_ROOT\}\// {
        name=$NF; gsub(/"/, "", name); print name
    }
' "${ROOT}/bin/pi-run" | LC_ALL=C sort)"
assert_component_set "launcher loading" "${actual}"

actual="$(grep '^for required in ' "${ROOT}/scripts/build-release" |
    grep -oE 'lib/pi-run/[A-Za-z0-9._-]+\.sh' | sed 's|.*/||' | LC_ALL=C sort)"
assert_component_set "release build" "${actual}"

installer_line="$(grep '^for COMPONENT_NAME in ' "${ROOT}/install.sh")"
installer_line="${installer_line#for COMPONENT_NAME in }"
installer_line="${installer_line%; do}"
actual="$(for component in ${installer_line}; do printf '%s\n' "${component}"; done | LC_ALL=C sort)"
assert_component_set "installer" "${actual}"

for component in ${EXPECTED}; do
    path="${ROOT}/lib/pi-run/${component}"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe source component: ${component}"
    [[ "$(stat -c %a "${path}")" == 644 ]] || fail "source component mode is not 644: ${component}"
    [[ "$(stat -c %h "${path}")" == 1 ]] || fail "source component is hard-linked: ${component}"
done

runtime_expected="$(printf '%-19s  %-6s  %s\n' \
    NAME TYPE DESCRIPTION \
    all group 'Every maintained optional runtime capability' \
    database-clients bundle 'PostgreSQL, Redis, MySQL, and SQLite clients' \
    flutter-development bundle 'Flutter and Dart development SDKs' \
    headless-gui bundle 'Headless Linux GUI, graphics, audio, and XKB support' \
    java-development bundle 'OpenJDK and Maven development tools' \
    kubernetes bundle 'kubectl, Helm, Kustomize, and yq' \
    native-development bundle 'C, C++, Clang, CMake, Ninja, and debugger tools' \
    network-diagnostics bundle 'DNS, routing, connectivity, and tracing tools' \
    operations bundle 'Ansible and operations tooling' \
    python-development bundle 'Python, headers, pip, venv, and pipx' \
    rust-development bundle 'Rustup, Cargo, Rustfmt, and Clippy' \
    utility-belt bundle 'Shell, archive, XML, inspection, and utility tools')"
mkdir -p "${TMP}/runtime-fake-bin"
cat > "${TMP}/runtime-fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod 0755 "${TMP}/runtime-fake-bin/docker"
runtime_home="${TMP}/runtime-home"
runtime_actual="$(PATH="${TMP}/runtime-fake-bin:${PATH}" PI_RUN_HOME="${runtime_home}" \
    "${ROOT}/bin/pi-run" --profile absent runtime list)"
[[ "${runtime_actual}" == "${runtime_expected}" ]] \
    || fail "runtime list output differs from the release-owned catalog"
[[ "${runtime_actual}" != *$'\t'* ]] || fail "runtime list output contains tabs"
[[ ! -e "${runtime_home}" && ! -L "${runtime_home}" ]] \
    || fail "runtime list initialized or changed Pi-Run home"
if PI_RUN_HOME="${runtime_home}" "${ROOT}/bin/pi-run" runtime status >/dev/null 2>&1; then
    fail "unsupported runtime command unexpectedly succeeded"
fi

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
archive="${TMP}/release/pi-run-${version}.tar.gz"
actual="$(tar -tzf "${archive}" |
    sed -n "s|^pi-run-${version}/lib/pi-run/\([^/][^/]*\.sh\)$|\1|p" |
    LC_ALL=C sort)"
assert_component_set "release archive" "${actual}"

tar -xzf "${archive}" -C "${TMP}"
package="${TMP}/pi-run-${version}"
[[ ! -e "${package}/README.md" && ! -L "${package}/README.md" ]] \
    || fail "archive unexpectedly contains the repository README"
[[ -f "${package}/LICENSE" && ! -L "${package}/LICENSE" ]] \
    || fail "archive license is missing or unsafe"
cmp -s "${ROOT}/LICENSE" "${package}/LICENSE" \
    || fail "archive license differs from the repository license"
[[ -x "${package}/bin/pi-run" && ! -L "${package}/bin/pi-run" ]] \
    || fail "archive launcher is missing or unsafe"
for component in ${EXPECTED}; do
    path="${package}/lib/pi-run/${component}"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe archive component: ${component}"
    [[ "$(stat -c %a "${path}")" == 644 ]] || fail "archive component mode is not 644: ${component}"
    [[ "$(stat -c %h "${path}")" == 1 ]] || fail "archive component is hard-linked: ${component}"
done
runtime_packaged="$(PI_RUN_HOME="${runtime_home}" "${package}/bin/pi-run" runtime list)"
[[ "${runtime_packaged}" == "${runtime_expected}" ]] \
    || fail "packaged runtime list differs from source behavior"
packaged_full_runtime="${package}/templates/runtime/full-development.Dockerfile"
[[ -f "${packaged_full_runtime}" && ! -L "${packaged_full_runtime}" &&
   "$(stat -c %a "${packaged_full_runtime}")" == 644 ]] \
    || fail "release archive omits the safe full-development runtime template"
cmp "${FULL_RUNTIME_TEMPLATE}" "${packaged_full_runtime}" \
    || fail "packaged full-development runtime differs from source"

JAVA_TEST_DIR="${TMP}/java-host-ca"
mkdir -p "${JAVA_TEST_DIR}/helper" "${JAVA_TEST_DIR}/no-java-path"
cp "${ROOT}/docker/PiRunJavaTrustStore.java" "${JAVA_TEST_DIR}/helper/"
printf 'default-without-java\n' > "${JAVA_TEST_DIR}/no-java-default"
printf 'unused-host-bundle\n' > "${JAVA_TEST_DIR}/no-java-host"
printf 'stale\n' > "${JAVA_TEST_DIR}/no-java-temp"
PATH="${JAVA_TEST_DIR}/no-java-path" /bin/bash "${ROOT}/docker/java-trust-store.sh" \
    "${JAVA_TEST_DIR}/no-java-default" "${JAVA_TEST_DIR}/no-java-host" \
    "${JAVA_TEST_DIR}/no-java-temp" "${JAVA_TEST_DIR}/missing-helper"
[[ "$(< "${JAVA_TEST_DIR}/no-java-default")" == default-without-java ]] \
    || fail "no-Java trust setup changed the default store"
[[ ! -e "${JAVA_TEST_DIR}/no-java-temp" ]] \
    || fail "no-Java trust setup retained stale temporary data"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/O=Pi-Run Test/CN=Host CA Bridge Test' \
    -keyout "${JAVA_TEST_DIR}/ca.key" -out "${JAVA_TEST_DIR}/ca.crt" \
    >/dev/null 2>&1
cp /etc/ssl/certs/java/cacerts "${JAVA_TEST_DIR}/java-cacerts"
JAVA_TOOL_OPTIONS='-XX:InvalidPiRunJavaOption' \
JDK_JAVA_OPTIONS='-XX:InvalidPiRunJavaOption' \
_JAVA_OPTIONS='-XX:InvalidPiRunJavaOption' \
"${ROOT}/docker/java-trust-store.sh" \
    "${JAVA_TEST_DIR}/java-cacerts" "${JAVA_TEST_DIR}/ca.crt" \
    "${JAVA_TEST_DIR}/java-cacerts.tmp" "${JAVA_TEST_DIR}/helper"
expected_alias="pi-run-host-$(openssl x509 -in "${JAVA_TEST_DIR}/ca.crt" -outform DER | sha256sum | awk '{print $1}')"
keytool -list -keystore "${JAVA_TEST_DIR}/java-cacerts" -storepass changeit \
    -alias "${expected_alias}" >/dev/null \
    || fail "Java source helper omitted the synthetic host CA"
[[ "$(stat -c %a "${JAVA_TEST_DIR}/java-cacerts")" == 444 ]] \
    || fail "generated Java trust store is not immutable to the workload user"

printf 'not a certificate\n' > "${JAVA_TEST_DIR}/invalid.crt"
cp /etc/ssl/certs/java/cacerts "${JAVA_TEST_DIR}/invalid-cacerts"
cp "${JAVA_TEST_DIR}/invalid-cacerts" "${JAVA_TEST_DIR}/invalid-cacerts.before"
if "${ROOT}/docker/java-trust-store.sh" \
    "${JAVA_TEST_DIR}/invalid-cacerts" "${JAVA_TEST_DIR}/invalid.crt" \
    "${JAVA_TEST_DIR}/invalid-cacerts.tmp" "${JAVA_TEST_DIR}/helper" \
    >/dev/null 2>&1; then
    fail "Java trust setup accepted an invalid host bundle"
fi
cmp "${JAVA_TEST_DIR}/invalid-cacerts.before" "${JAVA_TEST_DIR}/invalid-cacerts" \
    || fail "invalid host input replaced the default Java trust store"
[[ ! -e "${JAVA_TEST_DIR}/invalid-cacerts.tmp" ]] \
    || fail "invalid host input left a temporary Java trust store"

mkdir "${JAVA_TEST_DIR}/empty-helper"
if "${ROOT}/docker/java-trust-store.sh" \
    "${JAVA_TEST_DIR}/invalid-cacerts" "${JAVA_TEST_DIR}/ca.crt" \
    "${JAVA_TEST_DIR}/missing-helper.tmp" "${JAVA_TEST_DIR}/empty-helper" \
    >/dev/null 2>&1; then
    fail "Java trust setup accepted a missing source helper"
fi
if "${ROOT}/docker/java-trust-store.sh" \
    "${JAVA_TEST_DIR}/missing-default" "${JAVA_TEST_DIR}/ca.crt" \
    "${JAVA_TEST_DIR}/missing-default.tmp" "${JAVA_TEST_DIR}/helper" \
    >/dev/null 2>&1; then
    fail "Java trust setup accepted a missing default trust store"
fi
[[ ! -e "${JAVA_TEST_DIR}/missing-helper.tmp" &&
   ! -e "${JAVA_TEST_DIR}/missing-default.tmp" ]] \
    || fail "missing Java trust inputs left temporary output"

echo "component layout and packaging tests passed"
