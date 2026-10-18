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

function parseAddress(address, family) {
  if (family === 4) {
    const parts = address.split(".");
    if (parts.length !== 4 || parts.some((part) => !/^(?:0|[1-9][0-9]{0,2})$/.test(part))) fail("invalid CIDR rule");
    const numbers = parts.map(Number);
    if (numbers.some((part) => part > 255)) fail("invalid CIDR rule");
    return numbers.reduce((result, part) => (result << 8n) | BigInt(part), 0n);
  }
  const canonical = new URL(`http://[${address}]/`).hostname.slice(1, -1);
  const [left, right = ""] = canonical.split("::");
  const leftParts = left ? left.split(":") : [];
  const rightParts = right ? right.split(":") : [];
  const groups = canonical.includes("::")
    ? [...leftParts, ...Array(8 - leftParts.length - rightParts.length).fill("0"), ...rightParts]
    : leftParts;
  if (groups.length !== 8) fail("invalid CIDR rule");
  return groups.reduce((result, part) => (result << 16n) | BigInt(`0x${part}`), 0n);
}

function parseCidr(value) {
  if (typeof value !== "string" || !value.includes("/")) fail("invalid CIDR rule");
  const separator = value.lastIndexOf("/");
  const address = value.slice(0, separator);
  const prefixText = value.slice(separator + 1);
  const family = isIP(address);
  if (!family || !/^(?:0|[1-9][0-9]{0,2})$/.test(prefixText)) fail("invalid CIDR rule");
  const bits = family === 4 ? 32 : 128;
  const prefix = Number(prefixText);
  if (prefix > bits) fail("invalid CIDR rule");
  const full = (1n << BigInt(bits)) - 1n;
  const mask = prefix === 0 ? 0n : (full << BigInt(bits - prefix)) & full;
  return { family, bits, prefix, address: parseAddress(address, family) & mask };
}

function formatCidr(parsed) {
  if (parsed.family === 4) {
    const parts = [24n, 16n, 8n, 0n].map((shift) => Number((parsed.address >> shift) & 255n));
    return `${parts.join(".")}/${parsed.prefix}`;
  }
  const groups = [];
  for (let shift = 112n; shift >= 0n; shift -= 16n) groups.push(((parsed.address >> shift) & 65535n).toString(16));
  const address = new URL(`http://[${groups.join(":")}]/`).hostname.slice(1, -1);
  return `${address}/${parsed.prefix}`;
}

const BLOCKED_CIDRS = [
  "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
  "::/128", "::1/128", "::ffff:0:0/96", "fe80::/10", "ff00::/8",
].map(parseCidr);

function normalizeCidr(value) {
  const parsed = parseCidr(value);
  for (const blocked of BLOCKED_CIDRS) {
    if (blocked.family !== parsed.family) continue;
    const prefix = Math.min(blocked.prefix, parsed.prefix);
    const full = (1n << BigInt(parsed.bits)) - 1n;
    const mask = prefix === 0 ? 0n : (full << BigInt(parsed.bits - prefix)) & full;
    if ((blocked.address & mask) === (parsed.address & mask)) fail("CIDR rule overlaps a blocked range");
  }
  return formatCidr(parsed);
}

function normalizeManualRule(value) {
  const rule = object(value, "manual network rule");
  const selectors = ["host", "domain", "cidr"].filter((key) => Object.hasOwn(rule, key));
  const allowedKeys = new Set([...selectors, "tcpPorts"]);
  if (selectors.length !== 1 || Object.keys(rule).some((key) => !allowedKeys.has(key))) fail("invalid manual network rule");
  const selector = selectors[0];
  const normalized = selector === "cidr"
    ? normalizeCidr(rule[selector])
    : exactHostname(rule[selector], `${selector} rule`);
  const result = { [selector]: normalized };
  if (rule.tcpPorts !== undefined) {
    if (!Array.isArray(rule.tcpPorts) || rule.tcpPorts.length === 0 ||
        rule.tcpPorts.some((port) => !Number.isInteger(port) || port < 1 || port > 65535) ||
        new Set(rule.tcpPorts).size !== rule.tcpPorts.length) fail("invalid tcpPorts in manual network rule");
    result.tcpPorts = [...rule.tcpPorts].sort((left, right) => left - right);
  }
  return result;
}

function manualRuleKey(rule) {
  const selector = ["host", "domain", "cidr"].find((key) => Object.hasOwn(rule, key));
  return `${selector}:${rule[selector]}:${rule.tcpPorts?.join(",") ?? "all"}`;
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

function optionalObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value : undefined;
}

function copilotHasDynamicEndpoint(credential) {
  const record = optionalObject(credential);
  if (!record) return false;
  if (typeof record.enterpriseUrl === "string" && record.enterpriseUrl.length > 0) return true;
  for (const token of [record.access, record.key]) {
    if (typeof token !== "string") continue;
    const match = /(?:^|;)proxy-ep=([^;]+)/i.exec(token);
    if (match && match[1].toLowerCase() !== "proxy.individual.githubcopilot.com") return true;
  }
  return false;
}

function bedrockHasDynamicEndpoint(config, credential) {
  const record = optionalObject(credential);
  const env = optionalObject(record?.env);
  if (env && ["AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION"].some((key) =>
    typeof env[key] === "string" && env[key].length > 0)) return true;
  const provider = optionalObject(config);
  if (!Array.isArray(provider?.models)) return false;
  return provider.models.some((model) => {
    const id = optionalObject(model)?.id;
    return typeof id === "string" && /^arn:aws(?:-[a-z0-9-]+)?:bedrock:/i.test(id);
  });
}

function validateProviderEndpointMode(providerId, config, configured, credential) {
  if ((providerId === "azure" || providerId === "google-vertex") && !configured.providerOverride) {
    fail(`provider ${providerId} requires an explicit HTTPS baseUrl in models.json for restricted networking`);
  }
  if (providerId === "github-copilot" && copilotHasDynamicEndpoint(credential)) {
    fail("provider github-copilot uses a credential-derived endpoint unsupported by restricted networking");
  }
  if (providerId === "amazon-bedrock" && bedrockHasDynamicEndpoint(config, credential)) {
    fail("provider amazon-bedrock uses a region-derived endpoint unsupported by restricted networking");
  }
}

async function main() {
  if (process.argv.length > 3) fail("usage: pi-run-network-policy-resolver [profile-directory]");
  const profileDir = process.argv[2] ?? "/profile";
  const profile = object(await readJson(join(profileDir, "profile.json"), true), "profile.json");
  const network = object(profile.network, "network configuration in profile.json");
  if (network.mode !== "restricted") fail("profile network mode is not restricted");
  if (Object.keys(network).some((key) => key !== "mode" && key !== "allow")) fail("invalid network configuration in profile.json");
  const allow = network.allow ?? [];
  if (!Array.isArray(allow)) fail("invalid allow rules in profile.json");
  const manualRules = allow.map(normalizeManualRule).sort((left, right) => {
    const leftKey = manualRuleKey(left);
    const rightKey = manualRuleKey(right);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
  const manualKeys = manualRules.map(manualRuleKey);
  if (new Set(manualKeys).size !== manualKeys.length) fail("duplicate manual network rule");

  const auth = object(await readJson(join(profileDir, "auth.json")), "auth.json");
  const models = object(await readJson(join(profileDir, "models.json")), "models.json");
  models.providers = object(models.providers ?? {}, "providers in models.json");
  const settings = object(await readJson(join(profileDir, "settings.json")), "settings.json");
  const builtins = new Map((await loadBuiltinProviders()).map((provider) => [provider.id, provider.baseUrls]));
  const modelHosts = new Set();

  for (const providerId of configuredProviderIds(auth, models, settings)) {
    const providerConfig = models.providers[providerId];
    const configured = configuredBaseUrls(providerConfig);
    validateProviderEndpointMode(providerId, providerConfig, configured, auth[providerId]);
    const urls = [...configured.urls];
    if (!configured.providerOverride) urls.push(...(builtins.get(providerId) ?? []));
    if (urls.length === 0) fail("could not resolve a configured model provider endpoint");
    for (const url of urls) modelHosts.add(endpointHostname(url, "provider metadata"));
    for (const host of AUXILIARY_HOSTS[providerId] ?? []) modelHosts.add(exactHostname(host, "provider auxiliary hostname"));
    if (builtins.has(providerId)) modelHosts.add("pi.dev");
  }
  if (modelHosts.size === 0 && manualRules.length === 0) fail("restricted profile resolved no TCP rules");

  process.stdout.write(`${JSON.stringify({
    schemaVersion: 1,
    modelRules: [...modelHosts].sort().map((host) => ({ host, tcpPorts: [443] })),
    manualRules,
  })}\n`);
}

main().catch((error) => {
  process.stderr.write(`pi-run-network-policy-resolver: ${error.message}\n`);
  process.exitCode = 1;
});
