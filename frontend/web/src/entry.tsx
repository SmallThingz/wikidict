import { createMemo, For, Show, Switch, Match } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { layout, type ListNode } from './layout';
import type { Block, Entry, Span } from './types';

type Props = { entry: Entry; prefix: string; navigate: (title: string, event: MouseEvent) => void };
type InlineProps = { span: Span; prefix: string; navigate: Props['navigate'] };
function Inline(props: InlineProps) {
  const s = () => props.span;
  const href = () => {
    const target = s().target;
    if (s().kind === 'external_link') return /^https?:\/\/[^\x00-\x20\x7f]+$/i.test(target) ? target : undefined;
    if (/^#reference-\d+$/.test(target)) return `#${props.prefix}-${target.slice(1)}`;
    const hash = target.indexOf('#');
    return `https://en.wiktionary.org/wiki/${encodeURIComponent(hash < 0 ? target : target.slice(0, hash))}${hash < 0 ? '' : '#' + encodeURIComponent(target.slice(hash + 1))}`;
  };
  return <Switch fallback={<Dynamic component={s().superscript ? 'sup' : s().subscript ? 'sub' : s().code ? 'code' : s().small ? 'small' : 'span'}
    class={`dict-inline dict-role-${s().role || 'normal'}`} classList={{ 'dict-bold': s().bold, 'dict-italic': s().italic, 'dict-strike': s().strike, 'dict-underline': s().underline }} lang={s().language || undefined}>
    <Switch fallback={<>{s().text}{s().trail}</>}>
      <Match when={s().kind === 'line_break'}><br /></Match>
      <Match when={s().kind === 'link' || s().kind === 'external_link'}><a href={href()} rel="noopener noreferrer" onClick={event => { if (s().kind === 'link' && !s().target.startsWith('#reference-')) props.navigate(s().target, event); }}>{s().text}{s().trail}</a></Match>
    </Switch>
  </Dynamic>}>
    <Match when={s().kind === 'template'}><details class="dict-template"><summary title="Unsupported template; inspect original source">{s().target} <span aria-hidden="true">?</span></summary><code>{'{{' + s().text + '}}'}</code></details></Match>
  </Switch>;
}
function Spans(props: { spans: Span[]; context: Props }) { return <For each={props.spans}>{span => <Inline span={span} prefix={props.context.prefix} navigate={props.context.navigate}/>}</For>; }
function Content(props: { block: Block; context: Props }) {
  const b = () => props.block;
  return <Switch fallback={<div class={`dict-block-content dict-content-${b().kind}`}><Spans spans={b().spans} context={props.context}/><Show when={b().feature?.language}><small class="dict-language-tag">{b().feature?.language}</small></Show></div>}>
    <Match when={b().kind === 'rule'}><hr class="dict-rule"/></Match>
    <Match when={b().kind === 'preformatted'}><pre class="dict-pre"><Spans spans={b().spans} context={props.context}/></pre></Match>
    <Match when={b().table}><div class="dict-table-scroll"><table class="dict-table"><Show when={b().table!.caption.length}><caption><Spans spans={b().table!.caption} context={props.context}/></caption></Show><tbody><For each={b().table!.rows}>{row => <tr><For each={row.cells}>{cell => <Dynamic component={cell.header ? 'th' : 'td'} colSpan={cell.colspan} rowSpan={cell.rowspan} scope={cell.header ? 'col' : undefined}><Spans spans={cell.spans} context={props.context}/></Dynamic>}</For></tr>}</For></tbody></table></div></Match>
  </Switch>;
}
function WikiList(props: { node: ListNode; context: Props }) {
  return <Dynamic component={props.node.tag} class="dict-wiki-list"><For each={props.node.items}>{item => <Dynamic component={props.node.tag === 'dl' ? item.block?.kind === 'term' ? 'dt' : 'dd' : 'li'}>
    <Show when={item.block}>{block => <Content block={block()} context={props.context}/>}</Show>
    <For each={item.children}>{node => <WikiList node={node} context={props.context}/>}</For>
  </Dynamic>}</For></Dynamic>;
}
function Blocks(props: { blocks: Block[]; context: Props }) {
  const groups = createMemo(() => layout(props.blocks));
  return <For each={groups()}>{group => 'list' in group ? <WikiList node={group.list} context={props.context}/> : <Show when={group.block.kind !== 'blank'}><div class={`dict-render-block dict-block-${group.block.kind}`}><Content block={group.block} context={props.context}/></div></Show>}</For>;
}
export function Reading(props: Props) {
  return <div class="dict-reading">
    <Show when={props.entry.status === 'invalid_payload'}><div class="dict-notice" role="alert">This record has an invalid semantic payload. Its original bytes remain available in the JSON view.</div></Show>
    <Show when={props.entry.preamble_spans?.length}><div class="dict-preamble"><Spans spans={props.entry.preamble_spans!} context={props}/></div></Show>
    <For each={props.entry.sections}>{(section, index) => <section class="dict-section" id={`${props.prefix}-${index()}`} data-level={section.level}>
      <Show when={section.level > 2 || props.entry.kind !== 'language'}><Dynamic component={`h${Math.max(2, Math.min(section.level - 1, 5))}`} classList={{ 'dict-subheading': section.level > 3 }}>{section.title}</Dynamic></Show>
      <Blocks blocks={section.blocks} context={props}/>
    </section>}</For>
    <Show when={props.entry.references?.length}><section class="dict-section dict-references"><h2>References</h2><ol><For each={props.entry.references}>{ref => <li id={`${props.prefix}-reference-${ref.number}`}><Spans spans={ref.spans} context={props}/></li>}</For></ol></section></Show>
  </div>;
}
