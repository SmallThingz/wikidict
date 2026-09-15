import { createSignal } from 'solid-js';
import type { Entry } from './types';

export type SavedWord = {
  key: string; title: string; language: string | null; kind: string; clue: string;
  savedAt?: number; lastViewed: number; views: number;
};
export type StudyStat = { right: number; wrong: number; last: number };
export type LearnSettings = {
  historyEnabled: boolean; historyLimit: number; quizLength: number;
  randomPool: 'all' | 'history' | 'bookmarks';
};
type Persisted = {
  history: SavedWord[]; bookmarks: SavedWord[]; study: Record<string, StudyStat>;
  settings: LearnSettings;
};
const storageKey = 'dict.learning.v1';
const defaults: LearnSettings = { historyEnabled: true, historyLimit: 100, quizLength: 10, randomPool: 'all' };
const empty = (): Persisted => ({ history: [], bookmarks: [], study: {}, settings: { ...defaults } });
const spansText = (spans: Entry['sections'][number]['blocks'][number]['spans']) =>
  spans.map(span => span.kind === 'template' ? '' : `${span.text}${span.trail}`).join('').replace(/\s+/g, ' ').trim();

export function clueFor(entry: Entry): string {
  for (const lexeme of entry.organization?.lexemes ?? []) {
    for (const sense of lexeme.definitions) {
      const block = entry.sections[lexeme.section]?.blocks[sense.block];
      if (!block) continue;
      const text = spansText(block.spans);
      if (text) return text.slice(0, 420);
    }
  }
  for (const section of entry.sections) for (const block of section.blocks) {
    if (block.kind === 'blank' || block.kind === 'rule') continue;
    const text = spansText(block.spans);
    if (text) return text.slice(0, 420);
  }
  return 'Definition unavailable in this export.';
}

export function savedWord(entry: Entry): SavedWord {
  const language = entry.language ?? null;
  return { key: `${entry.kind}\u0000${language ?? ''}\u0000${entry.title}`, title: entry.title,
    language, kind: entry.kind, clue: clueFor(entry), lastViewed: Date.now(), views: 1 };
}
function load(): Persisted {
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(storageKey) || 'null');
    if (!parsed || typeof parsed !== 'object') return empty();
    const value = parsed as Partial<Persisted>;
    const rawSettings = value.settings && typeof value.settings === 'object' ? value.settings : defaults;
    const randomPool = rawSettings.randomPool === 'history' || rawSettings.randomPool === 'bookmarks' ? rawSettings.randomPool : 'all';
    const settings: LearnSettings = {
      historyEnabled: typeof rawSettings.historyEnabled === 'boolean' ? rawSettings.historyEnabled : true,
      historyLimit: Number.isFinite(rawSettings.historyLimit) ? Math.max(1, Math.min(500, Math.trunc(rawSettings.historyLimit))) : 100,
      quizLength: Number.isFinite(rawSettings.quizLength) ? Math.max(3, Math.min(50, Math.trunc(rawSettings.quizLength))) : 10,
      randomPool,
    };
    const study = value.study && typeof value.study === 'object' ? Object.fromEntries(Object.entries(value.study).filter(([, stat]) => validStat(stat))) : {};
    return {
      history: Array.isArray(value.history) ? value.history.filter(validWord).slice(0, settings.historyLimit) : [],
      bookmarks: Array.isArray(value.bookmarks) ? value.bookmarks.filter(validWord).slice(0, 1000) : [],
      study,
      settings,
    };
  } catch { return empty(); }
}
function validWord(value: unknown): value is SavedWord {
  if (!value || typeof value !== 'object') return false;
  const word = value as Partial<SavedWord>;
  return typeof word.key === 'string' && typeof word.title === 'string' &&
    (word.language === null || typeof word.language === 'string') && typeof word.kind === 'string' &&
    typeof word.clue === 'string' && typeof word.lastViewed === 'number' && typeof word.views === 'number';
}
function validStat(value: unknown): value is StudyStat {
  if (!value || typeof value !== 'object') return false;
  const stat = value as Partial<StudyStat>;
  return Number.isFinite(stat.right) && Number.isFinite(stat.wrong) && Number.isFinite(stat.last) &&
    (stat.right ?? -1) >= 0 && (stat.wrong ?? -1) >= 0;
}
function persist(value: Persisted) {
  try { localStorage.setItem(storageKey, JSON.stringify(value)); } catch { /* Private mode / quota: keep memory state. */ }
}
export function createLearningStore() {
  const [state, setState] = createSignal<Persisted>(load());
  const update = (fn: (value: Persisted) => Persisted) => {
    const next = fn(state()); setState(next); persist(next);
  };
  const record = (entry: Entry) => {
    const word = savedWord(entry);
    update(value => {
      if (!value.settings.historyEnabled) return value;
      const previous = value.history.find(item => item.key === word.key);
      const merged = { ...word, views: (previous?.views ?? 0) + 1, lastViewed: Date.now() };
      const history = [merged, ...value.history.filter(item => item.key !== word.key)]
        .slice(0, Math.max(1, Math.min(500, value.settings.historyLimit)));
      return { ...value, history };
    });
  };
  const toggleBookmark = (entry: Entry) => {
    const word = savedWord(entry);
    update(value => {
      const exists = value.bookmarks.some(item => item.key === word.key);
      return { ...value, bookmarks: exists ? value.bookmarks.filter(item => item.key !== word.key) :
        [{ ...word, savedAt: Date.now() }, ...value.bookmarks] };
    });
  };
  const removeHistory = (key: string) => update(value => ({ ...value, history: value.history.filter(item => item.key !== key) }));
  const removeBookmark = (key: string) => update(value => ({ ...value, bookmarks: value.bookmarks.filter(item => item.key !== key) }));
  const clearHistory = () => update(value => ({ ...value, history: [] }));
  const answer = (key: string, right: boolean) => update(value => {
    const old = value.study[key] ?? { right: 0, wrong: 0, last: 0 };
    return { ...value, study: { ...value.study, [key]: { right: old.right + (right ? 1 : 0), wrong: old.wrong + (right ? 0 : 1), last: Date.now() } } };
  });
  const updateSettings = (patch: Partial<LearnSettings>) => update(value => {
    const settings = { ...value.settings, ...patch };
    settings.historyLimit = Math.max(1, Math.min(500, settings.historyLimit));
    settings.quizLength = Math.max(3, Math.min(50, settings.quizLength));
    return { ...value, settings, history: value.history.slice(0, settings.historyLimit) };
  });
  const clearStudy = () => update(value => ({ ...value, study: {} }));
  const isBookmarked = (key: string) => state().bookmarks.some(item => item.key === key);
  const pool = (fallback: SavedWord[]) => {
    const setting = state().settings.randomPool;
    if (setting === 'bookmarks') return state().bookmarks;
    if (setting === 'history') return state().history;
    const seen = new Set<string>();
    return [...state().bookmarks, ...state().history, ...fallback].filter(item => !seen.has(item.key) && !!seen.add(item.key));
  };
  return { state, record, toggleBookmark, removeHistory, removeBookmark, clearHistory, answer, updateSettings, clearStudy, isBookmarked, pool };
}
export type LearningStore = ReturnType<typeof createLearningStore>;
