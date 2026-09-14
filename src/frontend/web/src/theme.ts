import { createSignal, onCleanup } from 'solid-js';
export type Appearance = { mode: string; accent: string; font: string };
const key = 'dict.appearance.v1';
const validColor = (s: unknown): s is string => typeof s === 'string' && /^#[0-9a-f]{6}$/i.test(s);
const modes = ['system', 'light', 'dark', 'cool'];
export function useTheme(root: () => HTMLElement, inherited: boolean) {
  const media = matchMedia('(prefers-color-scheme: dark)');
  let saved: Partial<Appearance> = {};
  try { saved = JSON.parse(localStorage.getItem(key) || '{}') ?? {}; } catch { /* Storage may be disabled. */ }
  const [appearance, setAppearance] = createSignal<Appearance>({ mode: modes.includes(saved.mode ?? '') ? saved.mode! : 'system', accent: validColor(saved.accent) ? saved.accent : '', font: saved.font === 'mono' ? 'mono' : 'sans' });
  const apply = () => {
    if (inherited) return;
    const settings = appearance();
    const dark = settings.mode === 'dark' || settings.mode === 'cool' || (settings.mode === 'system' && media.matches);
    const cool = settings.mode === 'cool';
    const bg = cool ? '#303237' : dark ? '#121213' : '#ffffff';
    const fg = cool ? '#b0b4bd' : dark ? '#f8f8f8' : '#121213';
    const accent = settings.accent || (cool ? '#7c9fc4' : dark ? '#60a5fa' : '#2563eb');
    const style = root().style;
    style.setProperty('--site-bg', bg); style.setProperty('--site-fg', fg); style.setProperty('--site-accent', accent);
    style.setProperty('--site-font', settings.font === 'mono' ? 'ui-monospace,SFMono-Regular,Menlo,monospace' : 'system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif');
    root().dataset.theme = dark ? 'dark' : 'light'; root().style.colorScheme = dark ? 'dark' : 'light';
  };
  const update = (patch: Partial<Appearance>) => {
    setAppearance(previous => ({ ...previous, ...patch }));
    try { localStorage.setItem(key, JSON.stringify(appearance())); } catch { /* Apply in memory anyway. */ }
    apply();
  };
  media.addEventListener('change', apply);
  onCleanup(() => media.removeEventListener('change', apply));
  return { appearance, update, apply };
}
