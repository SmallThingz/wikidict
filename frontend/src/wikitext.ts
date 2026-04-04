import wtf from "wtf_wikipedia";
import wtfHtml from "wtf-plugin-html";

wtf.extend(wtfHtml as Function);

const SUPPRESSED_TEMPLATES =
  /\{\{\s*(?:trans-top|trans-mid|trans-bottom|checktrans-top|checktrans-mid|checktrans-bottom|rel-top|rel-mid|rel-bottom|col-top|col-bottom)\b[^{}]*\}\}\s*/gi;

export function renderWikitextHtml(source: string): string {
  const cleaned = source.replace(SUPPRESSED_TEMPLATES, "").trim();
  if (!cleaned) return "";

  const rawHtml = (wtf(cleaned) as unknown as { html(): string }).html();
  return normalizeRenderedHtml(rawHtml);
}

function normalizeRenderedHtml(html: string): string {
  if (typeof DOMParser === "undefined") return html.trim();

  const doc = new DOMParser().parseFromString(html, "text/html");

  for (const wrapper of Array.from(doc.querySelectorAll("div.section, div.text"))) {
    unwrapElement(wrapper);
  }

  for (const paragraph of Array.from(doc.querySelectorAll("p.paragraph"))) {
    if (!paragraph.textContent?.trim() && paragraph.children.length === 0) paragraph.remove();
  }

  for (const sentence of Array.from(doc.querySelectorAll("span.sentence"))) {
    if (!sentence.textContent?.trim() && sentence.children.length === 0) sentence.remove();
  }

  for (const list of Array.from(doc.querySelectorAll("ul.list"))) {
    normalizeList(list, doc);
  }

  for (const anchor of Array.from(doc.querySelectorAll("a[href]"))) {
    const href = anchor.getAttribute("href");
    if (!href) continue;

    const target = resolveWikiHref(href);
    if (!target) continue;

    anchor.setAttribute("href", `/entry/${encodeURIComponent(target)}`);
    anchor.classList.add("entry-link");
  }

  return doc.body.innerHTML.trim();
}

function unwrapElement(element: Element) {
  const parent = element.parentNode;
  if (!parent) return;
  while (element.firstChild) parent.insertBefore(element.firstChild, element);
  parent.removeChild(element);
}

function resolveWikiHref(href: string): string | null {
  if (href.startsWith("./")) return normalizeWikiTarget(href.slice(2));
  if (href.startsWith("/wiki/")) return normalizeWikiTarget(href.slice("/wiki/".length));
  return null;
}

function normalizeWikiTarget(target: string): string {
  return decodeURIComponent(target).replaceAll("_", " ").trim();
}

function normalizeList(list: Element, doc: Document) {
  let shouldBeOrdered = true;

  for (const item of Array.from(list.querySelectorAll(":scope > li"))) {
    const sentence = item.querySelector(":scope > .sentence");
    const text = sentence?.textContent ?? "";

    const orderedMatch = text.match(/^(\d+)\)\s+/);
    if (orderedMatch && sentence?.firstChild?.nodeType === Node.TEXT_NODE) {
      sentence.firstChild.textContent = sentence.firstChild.textContent?.replace(/^(\d+)\)\s+/, "") ?? "";
      continue;
    }

    shouldBeOrdered = false;

    if (sentence?.firstChild?.nodeType === Node.TEXT_NODE) {
      sentence.firstChild.textContent = sentence.firstChild.textContent?.replace(/^\*\s+/, "") ?? "";
    }
  }

  list.classList.add("entry-list");
  if (!shouldBeOrdered) return;

  const orderedList = doc.createElement("ol");
  orderedList.className = list.className;
  while (list.firstChild) orderedList.appendChild(list.firstChild);
  list.replaceWith(orderedList);
}
