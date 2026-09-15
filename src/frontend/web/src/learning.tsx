import { createMemo, createSignal, For, Show } from 'solid-js';
import type { Entry } from './types';
import type { LearningStore, SavedWord } from './learning';

type Panel = 'history' | 'bookmarks' | 'learn' | 'settings';
type Game = 'quiz' | 'cards' | 'scramble';
const panels: Panel[] = ['history', 'bookmarks', 'learn', 'settings'];
const games: { id: Game; label: string; hint: string }[] = [
  { id: 'quiz', label: 'Definition quiz', hint: 'Pick the word that matches a definition.' },
  { id: 'cards', label: 'Flashcards', hint: 'Recall first, reveal second.' },
  { id: 'scramble', label: 'Unscramble', hint: 'Put the letters back in order.' },
];
const pick = <T,>(values: T[], except?: T): T | undefined => {
  const available = except === undefined ? values : values.filter(value => value !== except);
  return available.length ? available[Math.floor(Math.random() * available.length)] : undefined;
};
const shuffle = <T,>(values: T[]) => {
  const out = [...values];
  for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [out[i], out[j]] = [out[j], out[i]]; }
  return out;
};
function WordRows(props: { words: SavedWord[]; empty: string; open: (word: SavedWord) => void; remove?: (word: SavedWord) => void }) {
  return <Show when={props.words.length} fallback={<p class="dict-learning-empty">{props.empty}</p>}>
    <div class="dict-learning-list"><For each={props.words}>{word => <div class="dict-learning-row">
      <button class="dict-learning-word" onClick={() => props.open(word)}><strong>{word.title}</strong><span>{word.language ?? word.kind.replaceAll('_', ' ')}</span><small>{word.clue}</small></button>
      <Show when={props.remove}><button class="dict-learning-remove" aria-label={`Remove ${word.title}`} onClick={() => props.remove?.(word)}>×</button></Show>
    </div>}</For></div>
  </Show>;
}

export function LearningPanel(props: {
  store: LearningStore; current?: Entry; fallback: SavedWord[];
  openWord: (word: SavedWord) => void; randomWord: () => void; close: () => void;
}) {
  const [panel, setPanel] = createSignal<Panel>('learn');
  const [game, setGame] = createSignal<Game>('quiz');
  const pool = createMemo(() => props.store.pool(props.fallback));
  const [question, setQuestion] = createSignal<SavedWord | undefined>(pick(pool()));
  const [answered, setAnswered] = createSignal<string | null>(null);
  const [quizScore, setQuizScore] = createSignal({ right: 0, total: 0 });
  const choices = createMemo(() => {
    const answer = question(); if (!answer) return [];
    const distractors = shuffle(pool().filter(word => word.key !== answer.key)).slice(0, 3);
    return shuffle([answer, ...distractors]);
  });
  const nextQuestion = () => { if (quizScore().total >= props.store.state().settings.quizLength) setQuizScore({ right: 0, total: 0 }); setQuestion(pick(pool(), question())); setAnswered(null); };
  const choose = (word: SavedWord) => {
    const answer = question(); if (!answer || answered() != null) return;
    const correct = word.key === answer.key;
    props.store.answer(answer.key, correct);
    setAnswered(word.key);
    setQuizScore(score => ({ right: score.right + (correct ? 1 : 0), total: score.total + 1 }));
  };
  const [card, setCard] = createSignal<SavedWord | undefined>(pick(pool()));
  const [revealed, setRevealed] = createSignal(false);
  const gradeCard = (right: boolean) => {
    const word = card(); if (!word) return;
    props.store.answer(word.key, right); setCard(pick(pool(), word)); setRevealed(false);
  };
  const scramble = (word?: SavedWord) => {
    if (!word) return '';
    const chars = Array.from(word.title); if (chars.length < 2) return word.title;
    let result = shuffle(chars).join('');
    if (result === word.title) result = [...chars.slice(1), chars[0]].join('');
    return result;
  };
  const [scrambleWord, setScrambleWord] = createSignal<SavedWord | undefined>(pick(pool().filter(word => Array.from(word.title).length > 2)));
  const [scrambleText, setScrambleText] = createSignal('');
  const [scrambleStatus, setScrambleStatus] = createSignal<'right' | 'wrong' | null>(null);
  const nextScramble = () => { setScrambleWord(pick(pool().filter(word => Array.from(word.title).length > 2), scrambleWord())); setScrambleText(''); setScrambleStatus(null); };
  const checkScramble = () => {
    const word = scrambleWord(); if (!word || scrambleStatus()) return;
    const right = scrambleText().trim().toLocaleLowerCase() === word.title.toLocaleLowerCase();
    props.store.answer(word.key, right); setScrambleStatus(right ? 'right' : 'wrong');
  };
  const studied = createMemo(() => Object.values(props.store.state().study).reduce((sum, stat) => sum + stat.right + stat.wrong, 0));
  return <div class="dict-learning-backdrop" role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) props.close(); }}>
    <section class="dict-learning-panel" role="dialog" aria-modal="true" aria-label="Learning and library">
      <header class="dict-learning-header"><div><span class="dict-eyebrow">YOUR DICTIONARY</span><h2>Learn & remember</h2></div><button class="dict-learning-close" aria-label="Close" onClick={props.close}>×</button></header>
      <nav class="dict-learning-tabs" aria-label="Library sections"><For each={panels}>{value => <button aria-current={panel() === value ? 'page' : undefined} onClick={() => setPanel(value)}>{value[0].toUpperCase() + value.slice(1)}</button>}</For></nav>
      <div class="dict-learning-body">
        <Show when={panel() === 'history'}><section><div class="dict-learning-section-head"><div><h3>Recent words</h3><p>Words you opened on this device.</p></div><button disabled={!props.store.state().history.length} onClick={props.store.clearHistory}>Clear</button></div>
          <WordRows words={props.store.state().history} empty="Your history is empty." open={props.openWord} remove={word => props.store.removeHistory(word.key)}/></section></Show>
        <Show when={panel() === 'bookmarks'}><section><div class="dict-learning-section-head"><div><h3>Bookmarks</h3><p>Saved words stay available for practice.</p></div><span>{props.store.state().bookmarks.length}</span></div>
          <WordRows words={props.store.state().bookmarks} empty="Bookmark a word to keep it here." open={props.openWord} remove={word => props.store.removeBookmark(word.key)}/></section></Show>
        <Show when={panel() === 'learn'}><section><div class="dict-learning-hero"><div><span class="dict-eyebrow">PRACTICE</span><h3>{pool().length} words ready</h3><p>{studied()} answers recorded locally.</p></div><button class="dict-primary" onClick={props.randomWord}>Random word</button></div>
          <div class="dict-game-picker"><For each={games}>{item => <button aria-pressed={game() === item.id} onClick={() => setGame(item.id)}><strong>{item.label}</strong><small>{item.hint}</small></button>}</For></div>
          <Show when={game() === 'quiz'}><div class="dict-game-card"><div class="dict-game-score"><span>Definition quiz</span><strong>{quizScore().right}/{quizScore().total} · {props.store.state().settings.quizLength} questions</strong></div><Show when={question()} fallback={<p>Add at least one word to history or bookmarks first.</p>}>{answer => <><p class="dict-quiz-clue">{answer().clue}</p><div class="dict-quiz-choices"><For each={choices()}>{choice => <button classList={{ correct: answered() != null && choice.key === answer().key, wrong: answered() === choice.key && choice.key !== answer().key }} disabled={answered() != null} onClick={() => choose(choice)}>{choice.title}</button>}</For></div><Show when={answered() != null}><div class="dict-game-result"><span>{answered() === answer().key ? 'Correct.' : `Answer: ${answer().title}`}</span><button onClick={nextQuestion}>Next</button></div></Show></>}</Show></div></Show>
          <Show when={game() === 'cards'}><div class="dict-game-card"><div class="dict-game-score"><span>Flashcard</span><small>Say the meaning before revealing it.</small></div><Show when={card()} fallback={<p>Add words to practice first.</p>}>{word => <><button class="dict-flashcard" onClick={() => setRevealed(value => !value)}><strong>{word().title}</strong><span>{revealed() ? word().clue : 'Tap to reveal the definition'}</span></button><Show when={revealed()}><div class="dict-card-grades"><button onClick={() => gradeCard(false)}>Again</button><button class="dict-primary" onClick={() => gradeCard(true)}>Got it</button></div></Show></>}</Show></div></Show>
          <Show when={game() === 'scramble'}><div class="dict-game-card"><div class="dict-game-score"><span>Unscramble</span><small>Use the clue if you get stuck.</small></div><Show when={scrambleWord()} fallback={<p>Add longer words to practice first.</p>}>{word => <><div class="dict-scramble-word" aria-label="Scrambled word">{scramble(word())}</div><p class="dict-scramble-clue">{word().clue}</p><div class="dict-scramble-input"><input value={scrambleText()} onInput={event => { setScrambleText(event.currentTarget.value); setScrambleStatus(null); }} onKeyDown={event => { if (event.key === 'Enter') checkScramble(); }} placeholder="Type the word" autocomplete="off"/><button class="dict-primary" onClick={checkScramble}>Check</button></div><Show when={scrambleStatus()}>{status => <div class="dict-game-result"><span>{status() === 'right' ? 'Correct.' : `Not quite — ${word().title}`}</span><button onClick={nextScramble}>Next</button></div>}</Show></>}</Show></div></Show>
        </section></Show>
        <Show when={panel() === 'settings'}><section><div class="dict-learning-section-head"><div><h3>Learning settings</h3><p>Stored only in this browser.</p></div></div>
          <div class="dict-settings-grid"><label><span>Remember viewed words</span><input type="checkbox" checked={props.store.state().settings.historyEnabled} onChange={event => props.store.updateSettings({ historyEnabled: event.currentTarget.checked })}/></label>
            <label><span>History limit</span><select value={props.store.state().settings.historyLimit} onChange={event => props.store.updateSettings({ historyLimit: Number(event.currentTarget.value) })}><option value="25">25</option><option value="100">100</option><option value="250">250</option><option value="500">500</option></select></label>
            <label><span>Quiz length</span><select value={props.store.state().settings.quizLength} onChange={event => props.store.updateSettings({ quizLength: Number(event.currentTarget.value) })}><option value="5">5</option><option value="10">10</option><option value="20">20</option><option value="50">50</option></select></label>
            <label><span>Random word source</span><select value={props.store.state().settings.randomPool} onChange={event => props.store.updateSettings({ randomPool: event.currentTarget.value as 'all' | 'history' | 'bookmarks' })}><option value="all">Dictionary + saved words</option><option value="history">History</option><option value="bookmarks">Bookmarks</option></select></label></div>
          <div class="dict-settings-danger"><button onClick={props.store.clearStudy}>Reset learning scores</button><button onClick={props.store.clearHistory}>Clear history</button></div>
        </section></Show>
      </div>
    </section>
  </div>;
}
