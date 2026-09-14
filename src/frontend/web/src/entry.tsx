import { createMemo, For, Show, Switch, Match } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { layout, type ListNode } from './layout';
import type { Block, Entry, Lexeme, Sense, Span } from './types';
import { kindGroups, commonPronunciations, reveal } from './organization';

type Props = { entry: Entry; prefix: string; navigate: (title: string, event: MouseEvent, language?: string) => void };
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
      <Match when={s().kind === 'link' || s().kind === 'external_link'}><a href={href()} rel="noopener noreferrer" onClick={event => { if (s().target.startsWith('#reference-')) { event.preventDefault(); reveal(document.getElementById(`${props.prefix}-${s().target.slice(1)}`)); } else if (s().kind === 'link') props.navigate(s().target, event, s().language); }}>{s().text}{s().trail}</a></Match>
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
function Evidence(props: { indices: number[]; lexeme: Lexeme; context: Props; title: string; folded?: boolean }) {
  const blocks = () => props.context.entry.sections[props.lexeme.section].blocks;
  return <Show when={props.indices.length}>{_value => <Dynamic component={props.folded ? 'details' : 'div'} class={`dict-evidence ${props.folded ? 'dict-evidence-folded' : ''}`}>
    <Dynamic component={props.folded ? 'summary' : 'h5'}>{props.title}</Dynamic>
    <For each={props.indices}>{index => <div class="dict-evidence-item"><Content block={blocks()[index]} context={props.context}/></div>}</For>
  </Dynamic>}</Show>;
}
function Senses(props: { lexeme: Lexeme; context: Props; parent: number | null }) {
  const senses = () => props.lexeme.definitions.map((sense, index) => ({sense,index})).filter(item => item.sense.parent === props.parent);
  const block = (sense: Sense) => props.context.entry.sections[props.lexeme.section].blocks[sense.block];
  return <ol class="dict-senses" role="list"><For each={senses()}>{(item, ordinal) => <li data-sense={item.index}>
    <div class="dict-sense-heading"><span class="dict-sense-number" aria-label={`Definition ${block(item.sense).number || ordinal() + 1}`}>{block(item.sense).number || ordinal() + 1}</span><div class="dict-definition"><Content block={block(item.sense)} context={props.context}/></div></div>
    <Show when={item.sense.form}>{form => <div class="dict-form-navigation"><span>{form().relation}</span><a href={`https://en.wiktionary.org/wiki/${encodeURIComponent(form().target)}`} onClick={event => props.context.navigate(form().target + "#" + props.lexeme.kind,event,form().language)}>Read {form().target} <span aria-hidden="true">→</span></a></div>}</Show>
    <Evidence indices={item.sense.examples} lexeme={props.lexeme} context={props.context} title="Usage examples"/>
    <Evidence indices={item.sense.quotations} lexeme={props.lexeme} context={props.context} title="Quotations" folded/>
    <Evidence indices={item.sense.notes} lexeme={props.lexeme} context={props.context} title="Supporting notes" folded/>
    <Show when={props.lexeme.definitions.some(sense => sense.parent === item.index)}><Senses lexeme={props.lexeme} context={props.context} parent={item.index}/></Show>
  </li>}</For></ol>;
}
function Supplement(props: { index: number; context: Props }) {
  const section = () => props.context.entry.sections[props.index];
  return <details class="dict-supplement dict-section" id={`${props.context.prefix}-${props.index}`} data-section={section().title}>
    <summary><span>{section().title}</span><small>{section().deferred ? 'Not included' : 'Read section'}</small></summary>
    <div class="dict-supplement-body"><Show when={section().deferred} fallback={<Blocks blocks={section().blocks} context={props.context}/>}><p class="dict-deferred-note">This {section().deferred} body is in a separate language companion. It was not included in this core-only export. Re-export without --core-only after installing the companion to read it.</p></Show></div>
  </details>;
}
export function Reading(props: Props) {
  const groups = createMemo(() => kindGroups(props.entry));
  const hasLexemes = () => groups().length > 0;
  const pronunciation = createMemo(() => commonPronunciations(props.entry));
  return <div class="dict-reading">
    <Show when={props.entry.content === 'core'}><p class="dict-core-note" role="note">Core-only export. Definitions and usage examples are included; separate section bodies are labelled "Not included", not empty.</p></Show>
    <Show when={props.entry.status === 'invalid_payload'}><div class="dict-notice" role="alert">This record has an invalid semantic payload. Its original bytes remain available in the JSON view.</div></Show>
    <Show when={props.entry.preamble_spans?.length}><details class="dict-preamble"><summary>Entry context</summary><Spans spans={props.entry.preamble_spans!} context={props}/></details></Show>
    <Show when={hasLexemes()} fallback={<For each={props.entry.sections}>{(section,index) => <section class="dict-section" id={`${props.prefix}-${index()}`}><Show when={section.level > 2 || props.entry.kind !== 'language'}><h2>{section.title}</h2></Show><Show when={section.deferred} fallback={<Blocks blocks={section.blocks} context={props}/>}><p class="dict-deferred-note">Not included: {section.deferred} companion.</p></Show></section>}</For>}>
      <For each={pronunciation()}>{item => <Pronunciation index={item.index} language={item.language} context={props}/>}</For>
      <MediaGallery entry={props.entry}/>
      <div class="dict-reader-intro"><span class="dict-eyebrow">MEANINGS &amp; USE</span><span>History and source evidence stay attached.</span></div>
      <For each={groups()}>{group => <section class="dict-kind-group" data-kind={group.kind}>
        <header class="dict-kind-header"><h2>{group.kind}<Show when={new Set(groups().map(g => g.language)).size > 1}><small class="dict-language-tag">{group.language}</small></Show></h2><span>{group.lexemes.reduce((n,l) => n + l.definitions.length, 0)} {group.lexemes.reduce((n,l) => n + l.definitions.length, 0) === 1 ? "definition" : "definitions"}<Show when={group.lexemes.length > 1}> · {group.lexemes.length} entries</Show></span></header>
        <For each={group.lexemes}>{lexeme => <article class="dict-lexeme dict-section" id={`${props.prefix}-${lexeme.section}`} data-section={props.entry.sections[lexeme.section].title}>
          <Show when={lexeme.etymology !== null}>{_value => <div class="dict-origin"><span>{props.entry.sections[lexeme.etymology!].title.replace('Etymology','Origin')}</span><button onClick={() => reveal(document.getElementById(`${props.prefix}-${lexeme.etymology}`))}>History <span aria-hidden="true">↗</span></button></div>}</Show>
          <Headword lexeme={lexeme} context={props}/>
          <Senses lexeme={lexeme} context={props} parent={null}/>
          <Show when={lexeme.other_blocks.some(index => props.entry.sections[lexeme.section].blocks[index].kind !== 'blank')}><details class="dict-extra-blocks"><summary>Additional material for this entry</summary><For each={lexeme.other_blocks}>{index => <Content block={props.entry.sections[lexeme.section].blocks[index]} context={props}/>}</For></details></Show>
          <For each={lexeme.related_sections}>{index => <Supplement index={index} context={props}/>}</For>
        </article>}</For>
      </section>}</For>
      <section class="dict-supporting"><h2>History &amp; supporting material</h2><p>{props.entry.content === 'core' ? 'Headings retain their original positions. The labelled bodies are not included in this export.' : 'All source sections are retained. Open the detail you need.'}</p>
        <For each={props.entry.organization!.other_sections.filter(index => !pronunciation().some(item => item.index === index))}>{index => <Show when={props.entry.sections[index].level > 2 || props.entry.sections[index].blocks.some(b => b.kind !== 'blank')}><Supplement index={index} context={props}/></Show>}</For>
      </section>
    </Show>
    <Show when={props.entry.references?.length}><details class="dict-section dict-references"><summary>Source references <span>{props.entry.references!.length}</span></summary><ol><For each={props.entry.references}>{ref => <li id={`${props.prefix}-reference-${ref.number}`}><Spans spans={ref.spans} context={props}/></li>}</For></ol></details></Show>
  </div>;
}

function Headword(props: { lexeme: Lexeme; context: Props }) {
  const blocks = () => props.lexeme.introduction.map(index => props.context.entry.sections[props.lexeme.section].blocks[index]).filter(b => b.kind !== 'blank');
  const spans = () => blocks().flatMap(b => b.spans);
  const words = () => spans().filter(span => span.role === 'headword');
  const hasContext = () => words().length > 0 && spans().some(span => span.role !== 'headword' && span.text.trim().length > 0);
  return <div class="dict-headword"><Show when={words().length} fallback={<Blocks blocks={blocks()} context={props.context}/>}><Spans spans={words()} context={props.context}/></Show><Show when={hasContext()}><details class="dict-headword-context"><summary>Media captions &amp; entry context</summary><Blocks blocks={blocks()} context={props.context}/></details></Show></div>;
}

function Pronunciation(props: { index: number; language: string; context: Props }) {
  const section = () => props.context.entry.sections[props.index];
  const blocks = () => section().blocks.filter(b => b.kind !== 'blank');
  return <details class="dict-pronunciation" id={`${props.context.prefix}-${props.index}`} data-section={section().title}>
    <summary><span class="dict-pronunciation-label">Pronunciation<Show when={props.language && props.language !== props.context.entry.language}> · {props.language}</Show></span><span class="dict-pronunciation-preview"><Spans spans={blocks()[0]?.spans || []} context={props.context}/></span><span class="dict-pronunciation-more">More</span></summary>
    <div class="dict-pronunciation-body"><Blocks blocks={blocks().slice(1)} context={props.context}/></div>
  </details>;
}

function MediaGallery(props: { entry: Entry }) {
  const assets = () => props.entry.media ?? [];
  const external = (url: string | null) => url && /^https:\/\//.test(url) ? url : undefined;
  return <Show when={assets().length}><details class="dict-media"><summary>Images &amp; audio <small>{assets().filter(m => m.data_url).length} embedded / {assets().length} referenced</small></summary>
    <div class="dict-media-grid"><For each={assets()}>{item => <figure>
      <Show when={item.data_url} fallback={<p class="dict-media-unavailable">Media not included in this export.</p>}>
        <Show when={item.kind === 'image'} fallback={<audio controls preload="metadata" src={item.data_url!} aria-label={item.caption || item.file}/> }><img src={item.data_url!} alt={item.caption || item.file} loading="lazy"/></Show>
      </Show>
      <figcaption><strong>{item.caption || item.file}</strong><span>{item.author}</span><a href={external(item.source_url) ?? `https://commons.wikimedia.org/wiki/${encodeURIComponent('File:' + item.file)}`} rel="noopener noreferrer">Source</a><Show when={item.license}> · <a href={external(item.license_url)} rel="license noopener noreferrer">{item.license}</a></Show><Show when={item.license_text}><details><summary>Full media license</summary><pre class="dict-license-text">{item.license_text}</pre></details></Show></figcaption>
    </figure>}</For></div>
  </details></Show>;
}
