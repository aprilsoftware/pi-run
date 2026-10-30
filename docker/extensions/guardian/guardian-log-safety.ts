// SPDX-License-Identifier: MIT

export function guardianLogText(value: string, limit = 2400, tail = false): string {
  // Best effort, not a guarantee for arbitrary embedded/encoded secrets. Do this
  // BEFORE truncation, so a long credential is not made unrecognizable by clipping.
  const cleaned = value
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g, "[PRIVATE KEY REDACTED]")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b/g, "[TOKEN REDACTED]")
    .replace(/\b(Authorization\s*:\s*(?:Bearer|Basic)\s+)[^\s'";]+/gi, "$1[REDACTED]")
    .replace(/\b((?:Set-Cookie|Cookie)\s*:\s*)[^\r\n'"]+/gi, "$1[REDACTED]")
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:)[^\s/@]+@/gi, "$1[REDACTED]@")
    .replace(/(\b(?:password|passwd|pwd|passphrase|token|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|secret)\b["']?\s*(?:[:=]\s*))(?:"(?:\\.|[^"\\])*"|'[^']*'|[^\s,;&|]+)/gi, "$1[REDACTED]")
    .replace(/((?:^|\s)(?:--user|-u|--password|--token|--api-key)\s+)(?:"(?:\\.|[^"\\])*"|'[^']*'|[^\s]+)/g, "$1[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[JWT REDACTED]")
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "");
  if (cleaned.length <= limit) return cleaned;
  if (tail) {
    const marker = "\n[... truncated ...]\n", head = Math.min(500, Math.floor(limit / 4));
    return cleaned.slice(0, head) + marker + cleaned.slice(-(limit - head - marker.length));
  }
  return cleaned.slice(0, Math.max(0, limit - 12)) + " [truncated]";
}
export function guardianLogValue(value: unknown, depth = 0): unknown {
  if (typeof value === "string") return guardianLogText(value);
  if (value === null || typeof value === "number" || typeof value === "boolean") return value;
  if (depth >= 7) return "[omitted: depth limit]";
  if (Array.isArray(value)) return [...value.slice(0, 24).map(v => guardianLogValue(v, depth + 1)),
    ...(value.length > 24 ? [`[${value.length - 24} more item(s) omitted]`] : [])];
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).slice(0, 32).map(([k, v]) =>
    [k, /password|passwd|passphrase|token|secret|api.?key|authorization|cookie|private.?key/i.test(k) && !/(?:Tokens$|^authorizationBasis$)/.test(k)
      ? "[REDACTED]" : guardianLogValue(v, depth + 1)]));
  return undefined;
}
