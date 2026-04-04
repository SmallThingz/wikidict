const API_TIMEOUT_MS = 5000;

type LookupPayload = {
  hits: ApiLookupHit[];
};

type SuggestPayload = {
  suggestions: ApiSuggestion[];
};

type RandomPayload = {
  word: string;
};

async function fetchJson<T>(url: string, failureMessage: string): Promise<T> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), API_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });
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

export type ApiStats = {
  entries: number;
  rawEntries: number;
  redirects: number;
  lookups: number;
  recordsBytes: number;
  path: string;
  version: number;
};

export type ApiEntry = {
  word: string;
  normalized: string;
  aliasOnly: boolean;
  altForms: string[];
  canonicalTargets: string[];
  incomingAliases: string[];
  raw: string;
  summary: string;
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

export async function fetchStats(): Promise<ApiStats> {
  return fetchJson<ApiStats>("/api/stats", "Failed to load dictionary stats");
}

export async function fetchLookup(term: string): Promise<ApiLookupHit[]> {
  const payload = await fetchJson<LookupPayload>(`/api/lookup/${encodeURIComponent(term)}`, "Failed to load dictionary entry");
  return payload.hits as ApiLookupHit[];
}

export async function fetchSuggestions(query: string, limit = 12): Promise<ApiSuggestion[]> {
  if (!query.trim()) return [];
  const payload = await fetchJson<SuggestPayload>(`/api/search?q=${encodeURIComponent(query)}&limit=${limit}`, "Failed to fetch suggestions");
  return payload.suggestions as ApiSuggestion[];
}

export async function fetchRandomWord(): Promise<string> {
  const payload = await fetchJson<RandomPayload>("/api/random", "Failed to load a random word");
  return payload.word as string;
}
