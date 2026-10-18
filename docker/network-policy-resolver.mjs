#!/usr/bin/env node
// SPDX-License-Identifier: MIT

import { lstat, readFile } from "node:fs/promises";
import { isIP } from "node:net";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_CONFIG_BYTES = 4 * 1024 * 1024;
const PI_PACKAGE = "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json";
const AUXILIARY_HOSTS = {
  anthropic: ["claude.ai", "platform.claude.com"],
  "github-copilot": ["github.com"],
  "kimi-coding": ["auth.kimi.com"],
  meta: ["auth.meta.com"],
  openai: ["auth.openai.com"],
  "openai-codex": ["api.openai.com", "auth.openai.com"],
  xai: ["auth.x.ai"],
};

function fail(message) {
  throw new Error(message);
}

async function readJson(path, required = false) {
  let info;
  try {
    info = await lstat(path);
  } catch (error) {
    if (!required && error?.code === "ENOENT") return {};
    fail(`missing profile configuration file: ${path.split("/").at(-1)}`);
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_CONFIG_BYTES) {
    fail(`unsafe profile configuration file: ${path.split("/").at(-1)}`);
  }
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    fail(`invalid JSON in profile configuration file: ${path.split("/").at(-1)}`);
  }
}

function object(value, label) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) fail(`invalid ${label}`);
  return value;
}

function exactHostname(value, label) {
  if (typeof value !== "string" || value.length > 253 || value !== value.toLowerCase() || isIP(value)) {
    fail(`invalid ${label}`);
  }
  const labels = value.split(".");
  if (labels.length < 2 || labels.some((part) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part))) {
    fail(`invalid ${label}`);
  }
  return value;
}

function endpointHostname(value, label) {
  if (typeof value !== "string") fail(`invalid HTTPS provider endpoint in ${label}`);
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`invalid HTTPS provider endpoint in ${label}`);
  }
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")) {
    fail(`invalid HTTPS provider endpoint in ${label}`);
  }
  try {
    return exactHostname(url.hostname.toLowerCase(), `provider hostname in ${label}`);
  } catch {
    fail(`invalid HTTPS provider endpoint in ${label}`);
  }
}

async function loadBuiltinProviders() {
  const metadataFile = process.env.PI_RUN_PROVIDER_METADATA_FILE;
  if (metadataFile) {
    const metadata = object(await readJson(metadataFile, true), "provider metadata");
    if (!Array.isArray(metadata.providers)) fail("invalid provider metadata");
    return metadata.providers.map((entry) => {
      object(entry, "provider metadata");
      if (typeof entry.id !== "string" || !Array.isArray(entry.baseUrls)) fail("invalid provider metadata");
      return { id: entry.id, baseUrls: entry.baseUrls };
    });
  }

  try {
    const modulePath = join(
      dirname(PI_PACKAGE),
      "node_modules/@earendil-works/pi-ai/dist/providers/all.js",
    );
    const { builtinProviders } = await import(pathToFileURL(modulePath));
    return builtinProviders().map((provider) => ({
      id: provider.id,
      baseUrls: [
        provider.baseUrl,
        ...(provider.getAllModels?.() ?? provider.getModels()).map((model) => model.baseUrl),
      ].filter(Boolean),
    }));
  } catch {
    fail("could not load bundled Pi provider metadata");
  }
}

function configuredProviderIds(auth, models, settings) {
  const ids = new Set([...Object.keys(auth), ...Object.keys(models.providers)]);
  if (typeof settings.defaultProvider === "string") ids.add(settings.defaultProvider);
  if (settings.enabledModels !== undefined) {
    if (!Array.isArray(settings.enabledModels)) fail("invalid enabledModels in settings.json");
    for (const pattern of settings.enabledModels) {
      if (typeof pattern !== "string") fail("invalid enabledModels in settings.json");
      const match = /^([^*?/[\],]+)\//.exec(pattern);
      if (match) ids.add(match[1]);
    }
  }
  return ids;
}

function configuredBaseUrls(config) {
  if (config === undefined) return { providerOverride: false, urls: [] };
  object(config, "provider configuration in models.json");
  const urls = [];
  let providerOverride = false;
  if (config.baseUrl !== undefined) {
    if (typeof config.baseUrl !== "string") fail("invalid provider baseUrl in models.json");
    urls.push(config.baseUrl);
    providerOverride = true;
  }
  if (config.models !== undefined) {
    if (!Array.isArray(config.models)) fail("invalid models list in models.json");
    for (const model of config.models) {
      object(model, "model definition in models.json");
      if (model.baseUrl !== undefined) {
        if (typeof model.baseUrl !== "string") fail("invalid model baseUrl in models.json");
        urls.push(model.baseUrl);
      }
    }
  }
  return { providerOverride, urls };
}

async function main() {
  if (process.argv.length > 3) fail("usage: pi-run-network-policy-resolver [profile-directory]");
  const profileDir = process.argv[2] ?? "/profile";
  const profile = object(await readJson(join(profileDir, "profile.json"), true), "profile.json");
  const network = object(profile.network, "network configuration in profile.json");
  if (network.mode !== "restricted") fail("profile network mode is not restricted");
  const additional = network.allowHosts ?? [];
  if (!Array.isArray(additional)) fail("invalid allowHosts in profile.json");
  const additionalHosts = [...new Set(additional.map((host) => exactHostname(host, "allowHosts entry")))].sort();

  const auth = object(await readJson(join(profileDir, "auth.json")), "auth.json");
  const models = object(await readJson(join(profileDir, "models.json")), "models.json");
  models.providers = object(models.providers ?? {}, "providers in models.json");
  const settings = object(await readJson(join(profileDir, "settings.json")), "settings.json");
  const builtins = new Map((await loadBuiltinProviders()).map((provider) => [provider.id, provider.baseUrls]));
  const modelHosts = new Set();

  for (const providerId of configuredProviderIds(auth, models, settings)) {
    const configured = configuredBaseUrls(models.providers[providerId]);
    const urls = [...configured.urls];
    if (!configured.providerOverride) urls.push(...(builtins.get(providerId) ?? []));
    if (urls.length === 0) fail("could not resolve a configured model provider endpoint");
    for (const url of urls) modelHosts.add(endpointHostname(url, "provider metadata"));
    for (const host of AUXILIARY_HOSTS[providerId] ?? []) modelHosts.add(exactHostname(host, "provider auxiliary hostname"));
    if (builtins.has(providerId)) modelHosts.add("pi.dev");
  }
  if (modelHosts.size === 0 && additionalHosts.length === 0) fail("restricted profile resolved no HTTPS hosts");

  process.stdout.write(`${JSON.stringify({
    schemaVersion: 1,
    modelHosts: [...modelHosts].sort(),
    additionalHosts,
  })}\n`);
}

main().catch((error) => {
  process.stderr.write(`pi-run-network-policy-resolver: ${error.message}\n`);
  process.exitCode = 1;
});
