import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

import { parse } from "node-html-parser";

const cacheDir = process.env.DICT_PARSOID_CACHE_DIR || "data/parsoid-cache";
const debugHtmlDir = process.env.DICT_PARSOID_DEBUG_HTML_DIR || "";
const userAgent =
  process.env.DICT_PARSOID_USER_AGENT ||
  "dict-parsoid-audit/1.0 (local developer tool; purpose: renderer comparison)";
const parsoidApiUrl =
  process.env.DICT_PARSOID_API_URL || "https://en.wiktionary.org/w/api.php";
const cacheVersion = "v5";

await fs.mkdir(cacheDir, { recursive: true });
if (debugHtmlDir) {
  await fs.mkdir(debugHtmlDir, { recursive: true });
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

for await (const line of rl) {
  if (!line.trim()) continue;

  let request;
  try {
    request = JSON.parse(line);
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        kind: "worker_error",
        summary: `invalid worker request JSON: ${String(error)}`,
        our: "",
        parsoid: "",
      }) + "\n",
    );
    continue;
  }

  try {
    const ourSections = normalizeOurSections(request.sections ?? []);
    const parsoidSections = await loadParsoidSections(request.title ?? "Test", request.raw ?? "");
    const diff = compareSections(ourSections, parsoidSections);

    process.stdout.write(
      JSON.stringify(
        diff
          ? {
              ok: false,
              kind: "mismatch",
              summary: diff.summary,
              our: diff.our,
              parsoid: diff.parsoid,
            }
          : { ok: true },
      ) + "\n",
    );
  } catch (error) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        kind: "parsoid_error",
        summary: formatError(error),
        our: "",
        parsoid: "",
      }) + "\n",
    );
  }
}

async function loadParsoidSections(title, raw) {
  const filteredRaw = stripAuditExcludedWikitext(raw);
  const key = crypto.createHash("sha1").update(cacheVersion).update("\0").update(title).update("\0").update(filteredRaw).digest("hex");
  const cachePath = path.join(cacheDir, `${key}.json`);

  try {
    const cached = JSON.parse(await fs.readFile(cachePath, "utf8"));
    if (Array.isArray(cached)) return cached;
  } catch {}

  const html = await fetchParsoidHtml(title, filteredRaw);

  if (debugHtmlDir) {
    await fs.writeFile(path.join(debugHtmlDir, `${key}.html`), html, "utf8");
  }

  const normalized = normalizeParsoidHtml(title, html);
  await fs.writeFile(cachePath, JSON.stringify(normalized), "utf8");
  return normalized;
}

function stripAuditExcludedWikitext(raw) {
  const lines = String(raw || "").split("\n");
  const out = [];
  let skipLevel = null;

  for (const line of lines) {
    const rawLine = line.replace(/\r$/, "");
    const trimmed = rawLine.trim();
    const heading = parseHeadingLine(trimmed);
    if (heading) {
      if (skipLevel !== null && heading.level <= skipLevel) {
        skipLevel = null;
      }
      if (skipLevel === null && isExcludedAuditHeading(heading.title)) {
        skipLevel = heading.level;
      }
    }

    if (skipLevel !== null) {
      continue;
    }
    if (isExcludedAuditInlineLine(trimmed)) {
      continue;
    }
    out.push(line);
  }

  return out.join("\n");
}

function parseHeadingLine(line) {
  const trimmed = String(line || "").trim();
  const match = /^(={2,6})\s*(.*?)\s*\1$/.exec(trimmed);
  if (!match) return null;
  const title = match[2].trim();
  if (!title) return null;
  return { level: match[1].length, title };
}

function isExcludedAuditHeading(title) {
  const normalized = String(title || "").trim().toLowerCase();
  return normalized === "quotations" || normalized === "references" || normalized === "further reading";
}

function isExcludedAuditInlineLine(line) {
  const match = /^(#+)([:*]+)\s*(.*)$/.exec(String(line || "").trim());
  if (!match) return false;
  return isQuotationOnlyTemplate(match[3]);
}

function isQuotationOnlyTemplate(content) {
  const trimmed = String(content || "").trim();
  if (!trimmed.startsWith("{{") || !trimmed.endsWith("}}")) return false;
  const body = trimmed.slice(2, -2).trim();
  if (!body || body.includes("{{") || body.includes("}}")) return false;
  const name = body.split("|", 1)[0].trim();
  const lower = name.toLowerCase();
  return lower.startsWith("quote-") || name.startsWith("RQ:");
}

async function fetchParsoidHtml(title, raw) {
  const params = new URLSearchParams({
    action: "parse",
    format: "json",
    formatversion: "2",
    parser: "parsoid",
    prop: "text",
    contentmodel: "wikitext",
    title: title || "Test",
    text: raw,
  });

  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const response = await fetch(parsoidApiUrl, {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded; charset=utf-8",
          "user-agent": userAgent,
        },
        body: params,
      });

      if (!response.ok) {
        throw new Error(`Parsoid API request failed: HTTP ${response.status}`);
      }

      const payload = await response.json();
      if (payload?.error) {
        throw new Error(
          `Parsoid API error: ${payload.error.code || payload.error.info || JSON.stringify(payload.error)}`,
        );
      }

      return String(payload?.parse?.text || "");
    } catch (error) {
      lastError = error;
      if (attempt + 1 < 3) {
        await new Promise((resolve) => setTimeout(resolve, 250 * (attempt + 1)));
      }
    }
  }

  throw lastError;
}

function compareSections(ourSections, parsoidSections) {
  if (ourSections.length !== parsoidSections.length) {
    return {
      summary: `section count differs: ours=${ourSections.length} parsoid=${parsoidSections.length}`,
      our: summarizeSections(ourSections),
      parsoid: summarizeSections(parsoidSections),
    };
  }

  for (let i = 0; i < ourSections.length; i += 1) {
    const ours = ourSections[i];
    const theirs = parsoidSections[i];
    if (ours.title !== theirs.title) {
      return {
        summary: `section ${i + 1} title differs: ours=${JSON.stringify(ours.title)} parsoid=${JSON.stringify(theirs.title)}`,
        our: summarizeSection(ours),
        parsoid: summarizeSection(theirs),
      };
    }
    if (normalizeComparableLine(joinSectionLines(ours)) === normalizeComparableLine(joinSectionLines(theirs))) {
      continue;
    }
    if (ours.lines.length !== theirs.lines.length) {
      return {
        summary: `section ${JSON.stringify(ours.title)} block count differs: ours=${ours.lines.length} parsoid=${theirs.lines.length}`,
        our: summarizeSection(ours),
        parsoid: summarizeSection(theirs),
      };
    }
    for (let j = 0; j < ours.lines.length; j += 1) {
      if (normalizeComparableLine(ours.lines[j]) !== normalizeComparableLine(theirs.lines[j])) {
        return {
          summary: `section ${JSON.stringify(ours.title)} block ${j + 1} differs`,
          our: ours.lines[j],
          parsoid: theirs.lines[j],
        };
      }
    }
  }

  return null;
}

function summarizeSections(sections) {
  return sections.map(summarizeSection).join(" | ");
}

function summarizeSection(section) {
  return `${section.title || "<lead>"} => ${section.lines.join(" || ")}`;
}

function joinSectionLines(section) {
  return Array.isArray(section?.lines) ? section.lines.join(" ") : "";
}

function normalizeComparableLine(line) {
  return normalizeSemanticText(String(line || "").replaceAll("«", "").replaceAll("»", ""));
}

function normalizeOurSections(sections) {
  return sections
    .map((section) => ({
      title: section.title || "<lead>",
      lines: extractOurLines(section.html || ""),
    }))
    .filter((section) => shouldAuditSectionTitle(section.title))
    .filter((section) => section.lines.length > 0);
}

function extractOurLines(html) {
  const root = parse(`<root>${html}</root>`, {
    comment: false,
    lowerCaseTagName: false,
  });
  const lines = [];
  walkOurBlocks(root, lines);
  return lines;
}

function walkOurBlocks(node, lines) {
  if (!node?.childNodes) return;
  for (const child of node.childNodes) {
    if (!isElement(child)) continue;
    if (shouldSkipElement(child)) continue;

    if (isOurLeafBlock(child)) {
      lines.push(...extractBlockLines(child));
      continue;
    }

    if (child.tagName === "LI" && !hasInterestingBlockChild(child)) {
      lines.push(...extractBlockLines(child));
      continue;
    }

    if (child.tagName === "P") {
      lines.push(...extractBlockLines(child));
      continue;
    }

    walkOurBlocks(child, lines);
  }
}

function isOurLeafBlock(node) {
  if (node.tagName === "P" || node.tagName === "FIGCAPTION" || node.tagName === "DD" || node.tagName === "DT") {
    return true;
  }
  if (node.tagName !== "DIV") return false;
  const classes = new Set(node.classNames ?? []);
  return (
    classes.has("render-sense-gloss") ||
    classes.has("render-sense-example") ||
    classes.has("render-note")
  );
}

function normalizeParsoidHtml(title, html) {
  const root = parse(`<root>${html}</root>`, {
    comment: false,
    lowerCaseTagName: false,
  });

  const english = findEnglishSection(root);
  if (!english) return [];

  const state = {
    sections: [],
    current: null,
    title,
  };
  walkParsoidContent(english, state);
  for (const section of state.sections) {
    if (!shouldAuditSectionTitle(section.title)) {
      section.lines = [];
      continue;
    }
    section.lines = stripHeadwordLine(section.lines, title).filter(shouldKeepParsoidLine);
  }
  return state.sections.filter((section) => section.lines.length > 0);
}

function shouldAuditSectionTitle(title) {
  const normalized = normalizeText(String(title || "").replace(/\[\s*edit\s*\]/gi, ""));
  if (!normalized) return true;
  return !/^Pronunciation(?:\s+\d+)?$/i.test(normalized);
}

function findEnglishSection(root) {
  for (const section of root.querySelectorAll("section")) {
    const heading = section.querySelector("h2");
    if (heading && normalizeText(heading.text) === "English") return section;
  }
  return null;
}

function walkParsoidContent(node, state) {
  if (!node?.childNodes) return;

  for (const child of node.childNodes) {
    if (!isElement(child) || shouldSkipElement(child)) continue;

    if (child.tagName === "SECTION") {
      walkParsoidContent(child, state);
      continue;
    }

    if (/^H[1-6]$/.test(child.tagName)) {
      const level = Number(child.tagName.slice(1));
      if (level >= 3) {
        state.current = {
          title: normalizeText(child.text) || "<lead>",
          lines: [],
        };
        state.sections.push(state.current);
      }
      continue;
    }

    if (child.tagName === "P" || child.tagName === "LI" || child.tagName === "DD" || child.tagName === "DT" || child.tagName === "FIGCAPTION") {
      if (child.querySelector?.(".headword-line")) {
        continue;
      }
      if (!state.current) {
        state.current = {
          title: "<lead>",
          lines: [],
        };
        state.sections.push(state.current);
      }
      state.current.lines.push(...extractBlockLines(child));
      continue;
    }

    walkParsoidContent(child, state);
  }
}

function extractBlockLines(node) {
  const lines = [];
  let current = "";

  const flush = () => {
    const rendered = normalizeText(current);
    if (rendered) lines.push(rendered);
    current = "";
  };

  const walk = (child) => {
    if (!child) return;
    if (!isElement(child)) {
      current += child.rawText ?? child.text ?? "";
      return;
    }
    if (shouldSkipElement(child)) return;
    if (child.tagName === "BR") {
      flush();
      return;
    }
    if (child.tagName === "A") {
      const text = normalizeText(child.text);
      if (text) current += `«${text}»`;
      return;
    }

    for (const grandchild of child.childNodes ?? []) {
      walk(grandchild);
    }
  };

  walk(node);
  flush();

  const fallback = normalizeText(node.text ?? "");
  if ((lines.length === 0 || lines.every((line) => !hasSubstantiveText(line))) && hasSubstantiveText(fallback)) {
    return fallback
      .split(/\n+/)
      .map((line) => normalizeText(line))
      .filter(Boolean);
  }

  return lines;
}

function renderInline(node) {
  if (!node) return "";
  if (!isElement(node)) return normalizeText(node.rawText ?? node.text ?? "");
  if (shouldSkipElement(node)) return "";

  if (node.tagName === "A") {
    const text = normalizeText(node.text);
    if (!text) return "";
    return `«${text}»`;
  }

  if (node.tagName === "BR") return " ";

  let out = "";
  for (const child of node.childNodes ?? []) {
    if (isElement(child)) {
      out += renderInline(child);
    } else {
      out += child.rawText ?? child.text ?? "";
    }
  }
  return out;
}

function shouldSkipElement(node) {
  if (!isElement(node)) return false;

  const tag = node.tagName;
  if (tag === "STYLE" || tag === "META" || tag === "LINK" || tag === "SCRIPT") return true;

  const classes = new Set(node.classNames ?? []);
  if (
    classes.has("interproject-box") ||
    classes.has("headword-line") ||
    classes.has("noprint") ||
    classes.has("thumbcaption") ||
    classes.has("reference") ||
    classes.has("mw-editsection")
  ) {
    return true;
  }

  const rel = node.getAttribute?.("rel") || "";
  if (rel.includes("mw:PageProp/Category")) return true;

  const typeofAttr = node.getAttribute?.("typeof") || "";
  if (typeofAttr.includes("mw:Extension/templatestyles")) return true;

  if (tag === "SUP") return true;
  return false;
}

function hasInterestingBlockChild(node) {
  for (const child of node.childNodes ?? []) {
    if (!isElement(child)) continue;
    if (isOurLeafBlock(child) || child.tagName === "P" || child.tagName === "LI") return true;
  }
  return false;
}

function isElement(node) {
  return Boolean(node?.tagName);
}

function normalizeText(text) {
  return String(text || "")
    .normalize("NFKC")
    .replace(/[\u200B-\u200F\u2060\uFEFF]/g, "")
    .replace(/\u00AD/g, "")
    .replace(/&quot;/g, "\"")
    .replace(/&#34;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/[“”]/g, "\"")
    .replace(/[‘’]/g, "'")
    .replace(/\s+/g, " ")
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/([(\[])\s+/g, "$1")
    .replace(/\s+([)\]])/g, "$1")
    .trim();
}

function normalizeSemanticText(text) {
  return normalizeText(text)
    .replace(/\(([A-Za-zÀ-ÖØ-öø-ÿĀ-žḀ-ỹ' .-]+),\s*"([^"]+)"\)/g, "(\"$2\")")
    .replace(/‧/g, "-")
    .replace(/"/g, "")
    .toLowerCase();
}

function hasSubstantiveText(text) {
  return /[\p{L}\p{N}]/u.test(String(text || ""));
}

function stripHeadwordLine(lines, title) {
  if (!Array.isArray(lines) || lines.length <= 1) return lines;
  const normalizedTitle = normalizeText(title);
  if (!normalizedTitle) return lines;

  const first = lines[0];
  if (first === normalizedTitle || first.startsWith(`${normalizedTitle} (`)) {
    return lines.slice(1);
  }
  return lines;
}

function shouldKeepParsoidLine(line) {
  const trimmed = normalizeText(line);
  if (!trimmed) return false;
  if (trimmed === ".") return false;
  if (trimmed.startsWith("↑ ")) return false;
  if (trimmed.startsWith("Lua error in Module:interproject")) return false;
  return true;
}

function formatError(error) {
  if (!error) return "unknown parsoid error";
  if (error.stack) return error.stack;
  return String(error);
}
