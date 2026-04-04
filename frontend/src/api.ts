const API_TIMEOUT_MS = 5000;
const API_SCHEMA_VERSION = "rendered-sections-v2";
const API_BASE_URL = resolveApiBaseUrl();

type LookupPayload = {
  hits: ApiLookupHit[];
};

type SuggestPayload = {
  suggestions: ApiSuggestion[];
};

type RandomPayload = {
  word: string;
};

type WordOfDayPayload = {
  day: string;
  word: string;
};

type SystemThemePayload = ApiSystemTheme;

type JsonRecord = Record<string, unknown>;

async function fetchJson<T>(url: string, failureMessage: string): Promise<T> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), API_TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      signal: controller.signal,
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`${failureMessage} (${response.status})`);
    }
    return (await response.json()) as T;
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new Error(`${failureMessage} (request timed out)`);
    }
    throw error instanceof Error ? error : new Error(failureMessage);
  } finally {
    window.clearTimeout(timeout);
  }
}

function resolveApiBaseUrl(): string {
  const configured = import.meta.env.VITE_API_BASE_URL?.trim();
  if (configured) return configured.replace(/\/+$/, "");
  return "";
}

function apiUrl(path: string, params?: Record<string, string | number>): string {
  const search = new URLSearchParams();
  search.set("v", API_SCHEMA_VERSION);
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      search.set(key, String(value));
    }
  }
  const query = search.toString();
  const fullPath = query ? `${path}?${query}` : path;
  return `${API_BASE_URL}${fullPath}`;
}

export type ApiStats = {
  entries: number;
  rawEntries: number;
  redirects: number;
  lookups: number;
  recordsBytes: number;
  path: string;
  version: number;
};

export type ApiSystemTheme = {
  source: string;
  name: string;
  scheme: "light" | "dark";
  colors: {
    bg: string;
    page: string;
    panel: string;
    line: string;
    lineStrong: string;
    ink: string;
    muted: string;
    accent: string;
    accentStrong: string;
    accentSoft: string;
    glassBg: string;
    glassBorder: string;
  };
};

export type ApiEntry = {
  word: string;
  normalized: string;
  aliasOnly: boolean;
  aliasHintLabel: string;
  altForms: string[];
  canonicalTargets: string[];
  incomingAliases: string[];
  renderedSections: ApiRenderedSection[];
  raw: string;
  summary: string;
};

export type ApiRenderedSection = {
  id: string;
  title: string;
  level: number;
  html: string;
};

export type ApiLookupHit = {
  matched: string;
  kind: "title" | "alternative_form";
  entry: ApiEntry;
};

export type ApiSuggestion = {
  matched: string;
  word: string;
  kind: "title" | "alternative_form";
  aliasOnly: boolean;
  summary: string;
};

export type ApiWordOfDay = {
  day: string;
  word: string;
};

function readString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function readStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string");
}

function normalizeRenderedSections(value: unknown): ApiRenderedSection[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const record = item as JsonRecord;
    return [
      {
        id: readString(record.id),
        title: readString(record.title),
        level: typeof record.level === "number" ? record.level : 0,
        html: readString(record.html),
      },
    ];
  });
}

function normalizeLookupHit(value: unknown): ApiLookupHit | null {
  if (!value || typeof value !== "object") return null;
  const hit = value as JsonRecord;
  const entry = hit.entry;
  if (!entry || typeof entry !== "object") return null;
  const entryRecord = entry as JsonRecord;
  return {
    matched: readString(hit.matched),
    kind: hit.kind === "alternative_form" ? "alternative_form" : "title",
    entry: {
      word: readString(entryRecord.word),
      normalized: readString(entryRecord.normalized),
      aliasOnly: entryRecord.aliasOnly === true,
      aliasHintLabel: readString(entryRecord.aliasHintLabel),
      altForms: readStringArray(entryRecord.altForms),
      canonicalTargets: readStringArray(entryRecord.canonicalTargets),
      incomingAliases: readStringArray(entryRecord.incomingAliases),
      renderedSections: normalizeRenderedSections(entryRecord.renderedSections),
      raw: readString(entryRecord.raw),
      summary: readString(entryRecord.summary),
    },
  };
}

function payloadMissesRenderedSections(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const payload = value as JsonRecord;
  if (!Array.isArray(payload.hits)) return false;
  return payload.hits.some((hit) => {
    if (!hit || typeof hit !== "object") return false;
    const hitRecord = hit as JsonRecord;
    if (!hitRecord.entry || typeof hitRecord.entry !== "object") return false;
    const entry = hitRecord.entry as JsonRecord;
    return typeof entry.raw === "string" && entry.raw.length > 0 && !("renderedSections" in entry);
  });
}

export async function fetchStats(): Promise<ApiStats> {
  return fetchJson<ApiStats>(apiUrl("/api/stats"), "Failed to load dictionary stats");
}

export async function fetchSystemTheme(): Promise<ApiSystemTheme> {
  return fetchJson<SystemThemePayload>(apiUrl("/api/theme/system"), "Failed to load system theme");
}

export async function fetchLookup(term: string): Promise<ApiLookupHit[]> {
  const path = `/api/lookup/${encodeURIComponent(term)}`;
  let payload = await fetchJson<LookupPayload>(apiUrl(path), "Failed to load dictionary entry");
  if (payloadMissesRenderedSections(payload)) {
    payload = await fetchJson<LookupPayload>(
      apiUrl(path, { bust: Date.now() }),
      "Failed to load dictionary entry",
    );
  }
  if (!Array.isArray(payload.hits)) return [];
  return payload.hits.flatMap((hit) => {
    const normalized = normalizeLookupHit(hit);
    return normalized ? [normalized] : [];
  });
}

export async function fetchSuggestions(query: string, limit = 12): Promise<ApiSuggestion[]> {
  if (!query.trim()) return [];
  const payload = await fetchJson<SuggestPayload>(
    apiUrl("/api/search", { q: query, limit }),
    "Failed to fetch suggestions",
  );
  return payload.suggestions as ApiSuggestion[];
}

export async function fetchRandomWord(): Promise<string> {
  const payload = await fetchJson<RandomPayload>(apiUrl("/api/random"), "Failed to load a random word");
  return payload.word as string;
}

function formatLocalDayKey(date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export async function fetchWordOfDay(day = formatLocalDayKey()): Promise<ApiWordOfDay> {
  const payload = await fetchJson<WordOfDayPayload>(
    apiUrl("/api/word-of-day", { day }),
    "Failed to load the word of the day",
  );
  return {
    day: readString(payload.day, day),
    word: readString(payload.word),
  };
}
