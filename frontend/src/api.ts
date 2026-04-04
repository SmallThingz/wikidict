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
  const response = await fetch("/api/stats");
  if (!response.ok) throw new Error("Failed to load dictionary stats");
  return response.json();
}

export async function fetchLookup(term: string): Promise<ApiLookupHit[]> {
  const response = await fetch(`/api/lookup/${encodeURIComponent(term)}`);
  if (!response.ok) throw new Error("Failed to load dictionary entry");
  const payload = await response.json();
  return payload.hits as ApiLookupHit[];
}

export async function fetchSuggestions(query: string, limit = 12): Promise<ApiSuggestion[]> {
  if (!query.trim()) return [];
  const response = await fetch(`/api/search?q=${encodeURIComponent(query)}&limit=${limit}`);
  if (!response.ok) throw new Error("Failed to fetch suggestions");
  const payload = await response.json();
  return payload.suggestions as ApiSuggestion[];
}

export async function fetchRandomWord(): Promise<string> {
  const response = await fetch("/api/random");
  if (!response.ok) throw new Error("Failed to load a random word");
  const payload = await response.json();
  return payload.word as string;
}
