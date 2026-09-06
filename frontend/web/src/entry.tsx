import { For, Show, Switch, Match } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import type { Entry, Span } from './types';

type Props = { entry: Entry; prefix: string; navigate: (title: string, event: MouseEvent) => void };
function Inline(props: { span: Span; navigate: Props['navigate'] }) {
  const s = () => props.span;
  const external = () => /^https?:\/\//i.test(s().target);
  const href = () => s().kind === 'external_link' ? (external() ? s().target : undefined) : `https://en.wiktionary.org/wiki/${encodeURIComponent(s().target)}`;
  return <Switch fallback={<span classList={{ 'dict-bold': s().bold, 'dict-italic': s().italic }}>
    <Switch fallback={<>{s().text}{s().trail}</>}>
      <Match when={s().kind === 'line_break'}><br /></Match>
      <Match when={s().kind === 'link' || s().kind === 'external_link'}><a href={href()} rel="noopener noreferrer" onClick={event => { if (s().kind === 'link') props.navigate(s().target, event); }}>{s().text}{s().trail}</a></Match>
    </Switch>
  </span>}>
    <Match when={s().kind === 'template'}><details class="dict-template"><summary title="Unexpanded template">{'{' + s().target + '}'}</summary><code>{'{{' + s().text + '}}'}</code></details></Match>
  </Switch>;
}
export function Reading(props: Props) {
  return <div class="dict-reading">
    <Show when={props.entry.status === 'invalid_payload'}><div class="dict-notice" role="alert">This record has an invalid semantic payload. Its original bytes remain available in the JSON view.</div></Show>
    <Show when={props.entry.preamble}><details class="dict-preamble"><summary>Entry preamble</summary><pre>{props.entry.preamble}</pre></details></Show>
    <For each={props.entry.sections}>{(section, index) => <section class="dict-section" id={`${props.prefix}-${index()}`} data-level={section.level}>
      <Show when={section.level > 2 || props.entry.kind !== 'language'}><Dynamic component={`h${Math.max(2, Math.min(section.level - 1, 5))}`} classList={{ 'dict-subheading': section.level > 3 }}>{section.title}</Dynamic></Show>
      <div class="dict-blocks"><For each={section.blocks}>{block => <Show when={block.kind !== 'blank'}>
        <div class={`dict-block dict-block-${block.kind}`} style={{ '--depth': Math.min(Math.max(block.depth - 1, 0), 8) }}>
          <div class="dict-block-content"><For each={block.spans}>{span => <Inline span={span} navigate={props.navigate} />}</For>
            <Show when={block.feature?.language}><small class="dict-language-tag">{block.feature?.language}</small></Show>
          </div>
        </div>
      </Show>}</For></div>
    </section>}</For>
  </div>;
}
