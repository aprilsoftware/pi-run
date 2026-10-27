// SPDX-License-Identifier: MIT
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Input, matchesKey, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

export interface GuardViewSectionV1 { id: string; label: string; }
export interface GuardViewRowV1 { id: string; wide: string; compact: string; searchText: string; }
export interface GuardViewSnapshotV1 {
  schemaVersion: 1;
  loadedAt: string;
  rows: readonly GuardViewRowV1[];
  notices: readonly string[];
}
export interface GuardViewRequestV1 {
  schemaVersion: 1;
  title: string;
  compactTitle: string;
  wideHeader?: string;
  initialQuery?: string;
  fallbackText: string;
  unavailableText: string;
  emptyText: string;
  noMatchesText: string;
  missingSelectionText: string;
  incompleteNoticeText: string;
  sections: readonly GuardViewSectionV1[];
  load(signal: AbortSignal): Promise<GuardViewSnapshotV1>;
  details(rowId: string, sectionId: string): readonly string[];
}
export interface GuardViewTheme { fg(role: string, text: string): string; bg?(role: string, text: string): string; }
export interface GuardViewOpenOptions { request: GuardViewRequestV1; signal: AbortSignal; }

type ValidatedRequest = Omit<GuardViewRequestV1, "sections"> & { sections: readonly Readonly<GuardViewSectionV1>[] };
type ValidatedSnapshot = Omit<GuardViewSnapshotV1, "rows" | "notices"> & {
  rows: readonly Readonly<GuardViewRowV1>[];
  notices: readonly string[];
};

const MAX_ROWS = 30_000;
const MAX_SEARCH_BYTES = 16 * 1024 * 1024;
const MAX_DETAIL_LINES = 20_000;
const MAX_DETAIL_BYTES = 4 * 1024 * 1024;

function plain(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
function text(value: unknown, label: string, maximum: number, allowWhitespace = false): string {
  if (typeof value !== "string" || value.length > maximum || (!allowWhitespace && /[\u0000-\u001f\u007f]/.test(value)) ||
      (allowWhitespace && /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value))) {
    throw new Error(`Invalid Guard view ${label}`);
  }
  return value;
}
function identifier(value: unknown, label: string): string {
  const result = text(value, label, 96);
  if (!/^[a-z][a-z0-9-]{0,95}$/.test(result)) throw new Error(`Invalid Guard view ${label}`);
  return result;
}
function exact(value: Record<string, unknown>, keys: readonly string[], label: string): void {
  const actual = Object.keys(value).sort(), expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`Invalid Guard view ${label}`);
  }
}

export function validateGuardViewRequest(value: GuardViewRequestV1): ValidatedRequest {
  if (!plain(value)) throw new Error("Invalid Guard view request");
  exact(value, ["schemaVersion", "title", "compactTitle", "wideHeader", "initialQuery", "fallbackText", "unavailableText", "emptyText", "noMatchesText", "missingSelectionText", "incompleteNoticeText", "sections", "load", "details"]
    .filter(key => value[key] !== undefined), "request fields");
  if (value.schemaVersion !== 1 || typeof value.load !== "function" || typeof value.details !== "function" ||
      !Array.isArray(value.sections) || value.sections.length < 1 || value.sections.length > 8) {
    throw new Error("Invalid Guard view request");
  }
  const ids = new Set<string>();
  const sections = value.sections.map((candidate, index) => {
    if (!plain(candidate)) throw new Error("Invalid Guard view section");
    exact(candidate, ["id", "label"], "section fields");
    const id = identifier(candidate.id, `section ${index} identifier`), label = text(candidate.label, `section ${index} label`, 80);
    if (ids.has(id)) throw new Error("Duplicate Guard view section identifier");
    ids.add(id); return Object.freeze({ id, label });
  });
  return Object.freeze({
    schemaVersion: 1 as const,
    title: text(value.title, "title", 200),
    compactTitle: text(value.compactTitle, "compact title", 100),
    ...(value.wideHeader === undefined ? {} : { wideHeader: text(value.wideHeader, "header", 500) }),
    ...(value.initialQuery === undefined ? {} : { initialQuery: text(value.initialQuery, "initial query", 300, true).replace(/[\r\n\t]/g, " ") }),
    fallbackText: text(value.fallbackText, "fallback", 1000, true),
    unavailableText: text(value.unavailableText, "unavailable text", 500),
    emptyText: text(value.emptyText, "empty text", 500),
    noMatchesText: text(value.noMatchesText, "no-matches text", 500),
    missingSelectionText: text(value.missingSelectionText, "missing-selection text", 500),
    incompleteNoticeText: text(value.incompleteNoticeText, "incomplete-notice text", 500),
    sections: Object.freeze(sections), load: value.load, details: value.details,
  });
}

export function validateGuardViewSnapshot(value: GuardViewSnapshotV1): ValidatedSnapshot {
  if (!plain(value)) throw new Error("Invalid Guard view snapshot");
  exact(value, ["schemaVersion", "loadedAt", "rows", "notices"], "snapshot fields");
  if (value.schemaVersion !== 1 || !Array.isArray(value.rows) || value.rows.length > MAX_ROWS || !Array.isArray(value.notices) || value.notices.length > 4096) {
    throw new Error("Invalid Guard view snapshot");
  }
  const loadedAt = text(value.loadedAt, "snapshot time", 64), time = Date.parse(loadedAt);
  if (!Number.isFinite(time)) throw new Error("Invalid Guard view snapshot time");
  const ids = new Set<string>(); let searchBytes = 0;
  const rows = value.rows.map((candidate, index) => {
    if (!plain(candidate)) throw new Error("Invalid Guard view row");
    exact(candidate, ["id", "wide", "compact", "searchText"], "row fields");
    const id = text(candidate.id, `row ${index} identifier`, 300);
    if (!id || ids.has(id)) throw new Error("Invalid or duplicate Guard view row identifier");
    ids.add(id);
    const searchText = text(candidate.searchText, `row ${index} search text`, 2 * 1024 * 1024, true);
    searchBytes += Buffer.byteLength(searchText);
    if (searchBytes > MAX_SEARCH_BYTES) throw new Error("Guard view search data exceeds its limit");
    return Object.freeze({ id, wide: text(candidate.wide, `row ${index} wide label`, 4000),
      compact: text(candidate.compact, `row ${index} compact label`, 4000), searchText });
  });
  const notices = value.notices.map((notice, index) => text(notice, `notice ${index}`, 1000, true));
  return Object.freeze({ schemaVersion: 1 as const, loadedAt: new Date(time).toISOString(),
    rows: Object.freeze(rows), notices: Object.freeze(notices) });
}

export function validateGuardViewDetails(value: readonly string[]): readonly string[] {
  if (!Array.isArray(value) || value.length > MAX_DETAIL_LINES) throw new Error("Invalid Guard view details");
  let bytes = 0;
  const lines = value.map((line, index) => {
    const result = text(line, `detail line ${index}`, 128 * 1024);
    bytes += Buffer.byteLength(result);
    if (bytes > MAX_DETAIL_BYTES) throw new Error("Guard view details exceed their limit");
    return result;
  });
  return Object.freeze(lines);
}

function stamp(value: string): string {
  const time = Date.parse(value); return Number.isFinite(time) ? new Date(time).toISOString().slice(11, 19) : "unknown";
}
function errorMessage(cause: unknown): string {
  return (cause instanceof Error ? cause.message : String(cause)).replace(/[\u0000-\u001f\u007f]/g," ").slice(0,400);
}

class GuardViewer {
  private snapshot: ValidatedSnapshot;
  private selection = 0;
  private query: string;
  private panel: "list" | "detail" = "list";
  private detailKey = "";
  private section = 0;
  private scroll = 0;
  private pageSize = 10;
  private maxScroll = 0;
  private detailTotal = 0;
  private searching = false;
  private queryBefore = "";
  private readonly input = new Input();
  private refreshing = false;
  private refreshError = "";
  private disposed = false;
  private focus = false;
  private cache: { key: string; lines: readonly string[] } | undefined;
  private filteredCache: readonly Readonly<GuardViewRowV1>[] | undefined;
  constructor(private readonly request: ValidatedRequest, first: ValidatedSnapshot, private readonly signal: AbortSignal,
    private readonly theme: GuardViewTheme, private readonly rows: () => number, private readonly redraw: () => void,
    private readonly close: () => void) {
    this.snapshot = first; this.query = request.initialQuery ?? ""; this.input.setValue(this.query);
  }
  get focused(): boolean { return this.focus; }
  set focused(value: boolean) { this.focus = value; this.input.focused = value && this.searching; }
  invalidate(): void { this.cache = undefined; this.input.invalidate(); }
  dispose(): void { this.disposed = true; this.cache = undefined; this.filteredCache = undefined; }
  private changed(): void { this.cache = undefined; if (!this.disposed) this.redraw(); }
  private searchChanged(): void { this.filteredCache = undefined; this.selection = 0; this.changed(); }
  private matching(): readonly Readonly<GuardViewRowV1>[] {
    if (!this.filteredCache) {
      const terms = this.query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
      this.filteredCache = this.snapshot.rows.filter(row => terms.every(term => row.searchText.toLocaleLowerCase().includes(term)));
    }
    return this.filteredCache;
  }
  private async refresh(): Promise<void> {
    if (this.refreshing || this.disposed) return;
    const selected = this.matching()[this.selection]?.id;
    this.refreshing = true; this.refreshError = ""; this.changed();
    try {
      const next = validateGuardViewSnapshot(await this.request.load(this.signal)); if (this.disposed) return;
      this.snapshot = next; this.filteredCache = undefined;
      const index = this.matching().findIndex(row => row.id === selected);
      this.selection = index >= 0 ? index : Math.max(0, Math.min(this.selection, this.matching().length - 1));
      if (this.panel === "detail" && !next.rows.some(row => row.id === this.detailKey)) {
        this.panel = "list"; this.refreshError = this.request.missingSelectionText;
      }
    } catch (cause) {
      if (!this.disposed && !this.signal.aborted) this.refreshError = `Refresh failed: ${errorMessage(cause)}`;
    } finally { this.refreshing = false; this.changed(); }
  }
  handleInput(data: string): void {
    if (this.disposed) return;
    const key = (name: string) => matchesKey(data, name) || (/^[a-z]$/.test(name) && matchesKey(data, `shift+${name}`));
    if (key("ctrl+c")) { this.close(); return; }
    if (this.searching) {
      if (key("escape")) { this.searching = false; this.query = this.queryBefore; this.input.setValue(this.query); }
      else if (key("enter")) this.searching = false;
      else { this.input.handleInput(data); this.query = this.input.getValue().replace(/[\r\n\t]/g, " ").slice(0, 300); if (this.query !== this.input.getValue()) this.input.setValue(this.query); }
      this.input.focused = this.focus && this.searching; this.searchChanged(); return;
    }
    if (key("q")) { this.close(); return; }
    if (key("escape")) { if (this.panel === "list") this.close(); else { this.panel = "list"; this.scroll = 0; this.changed(); } return; }
    if (key("r")) { void this.refresh(); return; }
    if (key("/")) { this.panel = "list"; this.queryBefore = this.query; this.input.setValue(this.query); this.searching = true; this.input.focused = this.focus; this.changed(); return; }
    const delta = key("up") ? -1 : key("down") ? 1 : key("pageUp") ? -this.pageSize : key("pageDown") ? this.pageSize : 0;
    if (this.panel === "list") {
      const matches = this.matching();
      this.selection = key("home") ? 0 : key("end") ? Math.max(0, matches.length - 1) : Math.max(0, Math.min(Math.max(0, matches.length - 1), this.selection + delta));
      if (key("enter") && matches[this.selection]) { this.detailKey = matches[this.selection].id; this.panel = "detail"; this.section = 0; this.scroll = 0; }
    } else {
      const number = this.request.sections.findIndex((_section, index) => key(String(index + 1)));
      if (number >= 0) { this.section = number; this.scroll = 0; }
      else if (key("tab") || key("right")) { this.section = (this.section + 1) % this.request.sections.length; this.scroll = 0; }
      else if (key("shift+tab") || key("left")) { this.section = (this.section + this.request.sections.length - 1) % this.request.sections.length; this.scroll = 0; }
      this.scroll = key("home") ? 0 : key("end") ? this.maxScroll : Math.max(0, Math.min(this.maxScroll, this.scroll + delta));
    }
    this.changed();
  }
  render(width: number): string[] {
    if (this.disposed || width < 1) return [];
    const w = Math.max(1, width), terminalRows = Math.max(1, this.rows()), h = Math.min(Math.max(1, Math.floor(terminalRows * 0.88)), Math.max(1, terminalRows - 2));
    if (w < 20 || h < 7) return [truncateToWidth(`${this.request.compactTitle} · resize terminal or Esc`, w)].slice(0, h);
    const inner = w - 4, gray = (value: string) => this.theme.fg("muted", value);
    const frame = (value: string, selected = false) => {
      const safe = truncateToWidth(value, inner), pad = safe + " ".repeat(Math.max(0, inner - visibleWidth(safe)));
      let body = gray(pad);
      if (selected) body = this.theme.bg ? this.theme.bg("selectedBg", this.theme.fg("text", pad)) : `\x1b[7m${body}\x1b[27m`;
      return gray("│ ") + body + gray(" │");
    };
    const out: { text: string; selected?: boolean }[] = [
      { text: `${this.request.title}${this.refreshing ? " · refreshing" : ""}` },
      { text: `Snapshot ${stamp(this.snapshot.loadedAt)}${this.query ? ` · Search: ${this.query}` : ""}` },
    ];
    if (this.searching) out.push({ text: this.input.render(inner).join("") });
    if (this.panel === "list" && w >= 90 && this.request.wideHeader) out.push({ text: this.request.wideHeader });
    let help = "↑↓ Select  Enter Details  / Search  R Refresh  Esc Close";
    let content: { text: string; selected?: boolean }[] = [];
    const capacity = Math.max(1, h - 2 - out.length - 2); this.pageSize = capacity;
    if (this.panel === "list") {
      const matches = this.matching();
      if (!matches.length) content = [{ text: this.snapshot.rows.length ? this.request.noMatchesText : this.request.emptyText }];
      else {
        const page = Math.floor(this.selection / capacity) * capacity;
        content = matches.slice(page, page + capacity).map((row, index) => ({
          text: `${page + index === this.selection ? "›" : " "} ${w >= 90 ? row.wide : row.compact}`,
          selected: page + index === this.selection,
        }));
        out[1].text += ` · ${this.selection + 1}/${matches.length}`;
      }
    } else {
      const section = this.request.sections[this.section];
      out.push({ text: this.request.sections.map((item, index) => `${index + 1}:${index === this.section ? `[${item.label}]` : item.label}`).join("  ") });
      const cacheKey = `${this.detailKey}:${section.id}:${inner}`;
      if (this.cache?.key !== cacheKey) {
        try { this.cache = { key: cacheKey, lines: validateGuardViewDetails(this.request.details(this.detailKey, section.id)).flatMap(line => line ? wrapTextWithAnsi(line, inner) : [""]) }; }
        catch (cause) { this.cache = { key: cacheKey, lines: [`Details unavailable: ${errorMessage(cause)}`] }; }
      }
      const lines = this.cache.lines;
      help = `${this.request.sections.length > 1 ? `1–${this.request.sections.length} or Tab Section  ` : ""}↑↓ Scroll  PgUp/PgDn Page  R Refresh  Esc Back  Q Close`;
      const count = Math.max(1, h - 2 - out.length - 2); this.pageSize = count; this.detailTotal = lines.length; this.maxScroll = Math.max(0, lines.length - count);
      this.scroll = Math.min(this.scroll, this.maxScroll); content = lines.slice(this.scroll, this.scroll + count).map(value => ({ text: value }));
    }
    const available = Math.max(1, h - 2 - out.length - 2);
    out.push(...content.slice(0, available));
    while (out.length < h - 4) out.push({ text: "" });
    const position = this.panel === "detail" ? `Lines ${this.scroll + 1}–${Math.min(this.detailTotal, this.scroll + this.pageSize)}/${this.detailTotal} · ` : "";
    const notice = this.refreshError || (this.snapshot.notices.length ? `${position}${this.snapshot.notices.length} log read warning(s); ${this.request.incompleteNoticeText}` : `${position}Read-only · not a confirmation`);
    out.push({ text: notice }, { text: this.searching ? "Type to filter · Enter Apply · Esc Restore · Ctrl+C Close viewer" : help });
    return [gray("╭" + "─".repeat(w - 2) + "╮"), ...out.slice(0, h - 2).map(item => frame(item.text, item.selected)), gray("╰" + "─".repeat(w - 2) + "╯")]
      .map(line => truncateToWidth(line, w));
  }
}

export async function openGuardView(ctx: ExtensionContext, options: GuardViewOpenOptions): Promise<void> {
  const request = validateGuardViewRequest(options.request), signal = options.signal;
  const mode = (ctx as unknown as { mode?: string }).mode;
  if (!ctx.hasUI || (mode && !["tui", "interactive"].includes(mode))) { ctx.ui.notify(request.fallbackText, "info"); return; }
  const custom = (ctx.ui as unknown as { custom?: <T>(factory: (tui: any, theme: GuardViewTheme, keys: any, done: (result: T) => void) => any, options?: any) => Promise<T> }).custom;
  if (typeof custom !== "function") { ctx.ui.notify(request.unavailableText, "warning"); return; }
  signal.throwIfAborted();
  const first = validateGuardViewSnapshot(await request.load(signal)); signal.throwIfAborted();
  let close: (() => void) | undefined, finished = false;
  const abort = () => close?.(); signal.addEventListener("abort", abort, { once: true });
  try {
    await custom.call(ctx.ui, (tui: any, theme: GuardViewTheme, _keys: any, done: (result: undefined) => void) => {
      close = () => { if (!finished) { finished = true; done(undefined); } };
      return new GuardViewer(request, first, signal, theme, () => tui.terminal?.rows ?? process.stdout.rows ?? 24,
        () => { if (!finished && !signal.aborted) tui.requestRender(); }, close);
    }, { overlay: true, overlayOptions: { width: "96%", maxHeight: "90%", anchor: "center", margin: 1 },
      onHandle: () => { if (signal.aborted) close?.(); } });
  } finally { finished = true; signal.removeEventListener("abort", abort); }
}
