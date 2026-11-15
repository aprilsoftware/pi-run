#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
PI_WEB_ACCESS_DIR="${PI_WEB_ACCESS_DIR:-$(npm root -g)/pi-web-access}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] \
    || { echo 'web-access-compatibility-test: Pi package unavailable' >&2; exit 1; }
[[ -f "${PI_WEB_ACCESS_DIR}/package.json" ]] \
    || { echo 'web-access-compatibility-test: pi-web-access package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
printf '%s\n' '{"ssrf":{"trustEnvProxy":true}}' > "${TMP}/web-search.json"

PI_CODING_AGENT_DIR="${TMP}" PI_RUN_PROFILE_DIR="${TMP}" \
node --input-type=module - "${PI_PACKAGE_DIR}" "${PI_WEB_ACCESS_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [piDir, webDir, profileDir] = process.argv.slice(2);
const webPackage = JSON.parse(await readFile(join(webDir, 'package.json'), 'utf8'));
assert.equal(webPackage.version, '0.47.0');
assert.equal(webPackage.engines?.node, '>=22.19.0');
const [major, minor, patch] = process.versions.node.split('.').map(Number);
assert.ok(major > 22 || (major === 22 && (minor > 19 || (minor === 19 && patch >= 0))),
    `Node ${process.versions.node} does not satisfy pi-web-access ${webPackage.engines.node}`);

const configFile = join(profileDir, 'web-search.json');
const originalConfig = await readFile(configFile, 'utf8');
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist/core/extensions/loader.js')).href);
const loaded = await loadExtensions([join(webDir, 'index.ts')], process.cwd());
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
const extension = loaded.extensions[0];
assert.deepEqual([...extension.tools.keys()].sort(),
    ['fetch_content', 'get_search_content', 'source_check', 'web_enable', 'web_search']);

for (const toolName of ['web_search', 'source_check']) {
    const provider = extension.tools.get(toolName).definition.parameters.properties.provider;
    assert.equal(provider.type, 'string', `${toolName} provider must use Pi 1.5-compatible string schema`);
    assert.equal(provider.anyOf, undefined, `${toolName} provider must not expose the former array union`);
    assert.match(provider.description, /comma-separated names/);
}
assert.equal(await readFile(configFile, 'utf8'), originalConfig,
    'extension loading must not rewrite the restricted-mode web configuration');
console.log('PASS web access: 0.47.0 loads under Pi 1.5 with the restricted config and string provider contract');
NODE
