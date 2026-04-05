import crypto from "node:crypto";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { DatabaseSync } from "node:sqlite";

import { parse } from "node-html-parser";

const cacheDir = process.env.DICT_PARSOID_CACHE_DIR || "data/parsoid-cache";
const cacheDbPath = process.env.DICT_PARSOID_DB_PATH || "data/parsoid-cache.sqlite";
const debugHtmlDir = process.env.DICT_PARSOID_DEBUG_HTML_DIR || "";
const userAgent =
  process.env.DICT_PARSOID_USER_AGENT ||
  "dict-parsoid-audit/1.0 (local developer tool; purpose: renderer comparison)";
const parsoidApiUrl = process.env.DICT_PARSOID_API_URL || "https://en.wiktionary.org/w/api.php";
const phpCmd = process.env.DICT_PARSOID_PHP_CMD || "php";
const phpWorkerPath =
  process.env.DICT_PARSOID_PHP_WORKER || path.resolve("tools/parsoid-audit-worker/php_worker.php");
const cacheVersion = "parsoid-php-v0.22.2-v1";
const onlyCached = parseBooleanEnv("DICT_PARSOID_ONLY_CACHED", false);
const minParsoidIntervalMs = parseIntegerEnv("DICT_PARSOID_MIN_INTERVAL_MS", 1000);
const parsoidRetryBaseMs = parseIntegerEnv("DICT_PARSOID_RETRY_BASE_MS", 2000);
const maxParsoidRetries = parseIntegerEnv("DICT_PARSOID_MAX_RETRIES", 6);

let nextParsoidRequestAtMs = 0;

await fs.mkdir(cacheDir, { recursive: true });
await fs.mkdir(path.dirname(cacheDbPath), { recursive: true });
if (debugHtmlDir) {
  await fs.mkdir(debugHtmlDir, { recursive: true });
}

const db = new DatabaseSync(cacheDbPath);
db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA busy_timeout = 5000;
  CREATE TABLE IF NOT EXISTS parsoid_results (
    cache_key TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    raw_sha1 TEXT NOT NULL,
    cache_version TEXT NOT NULL,
    sections_json TEXT NOT NULL,
    html_text TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
  );
`);
const selectCachedResult = db.prepare(
  "SELECT sections_json FROM parsoid_results WHERE cache_key = ? AND cache_version = ?",
);
const upsertCachedResult = db.prepare(`
  INSERT INTO parsoid_results (
    cache_key,
    title,
    raw_sha1,
    cache_version,
    sections_json,
    html_text,
    created_at_ms,
    updated_at_ms
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(cache_key) DO UPDATE SET
    title = excluded.title,
    raw_sha1 = excluded.raw_sha1,
    cache_version = excluded.cache_version,
    sections_json = excluded.sections_json,
    html_text = excluded.html_text,
    updated_at_ms = excluded.updated_at_ms
`);

async function loadParsoidSections(title, raw) {
  const filteredRaw = stripAuditExcludedWikitext(raw);
  const key = crypto.createHash("sha1").update(cacheVersion).update("\0").update(title).update("\0").update(filteredRaw).digest("hex");
  const rawSha1 = crypto.createHash("sha1").update(filteredRaw).digest("hex");
  const cachedRow = selectCachedResult.get(key, cacheVersion);
  if (cachedRow?.sections_json) {
    return reAuditCachedSections(JSON.parse(cachedRow.sections_json));
  }

  const legacySections = await loadLegacyCachedSections(title, raw, filteredRaw);
  if (legacySections) {
    const nowMs = Date.now();
    upsertCachedResult.run(
      key,
      title,
      rawSha1,
      cacheVersion,
      JSON.stringify(legacySections),
      "",
      nowMs,
      nowMs,
    );
    return legacySections;
  }

  if (onlyCached) {
    throw new CacheMissError(title);
  }

  const html = await renderParsoidHtml(title, filteredRaw);

  if (debugHtmlDir) {
    await fs.writeFile(path.join(debugHtmlDir, `${key}.html`), html, "utf8");
  }

  const normalized = normalizeParsoidHtml(title, html);
  const nowMs = Date.now();
  upsertCachedResult.run(
    key,
    title,
    rawSha1,
    cacheVersion,
    JSON.stringify(normalized),
    html,
    nowMs,
    nowMs,
  );
  return normalized;
}

async function loadLegacyCachedSections(title, raw, filteredRaw) {
  for (const candidate of legacyCacheCandidates(title, raw, filteredRaw)) {
    try {
      const cached = JSON.parse(await fs.readFile(candidate.path, "utf8"));
      if (Array.isArray(cached)) {
        return reAuditCachedSections(cached);
      }
    } catch (error) {
      if (error?.code !== "ENOENT") {
        throw error;
      }
    }
  }
  return null;
}

function legacyCacheCandidates(title, raw, filteredRaw) {
  return [
    legacyCacheCandidate("v11", title, filteredRaw),
    legacyCacheCandidate("v9", title, filteredRaw),
    legacyCacheCandidate("v5", title, filteredRaw),
    legacyCacheCandidate("v4", title, filteredRaw),
    legacyCacheCandidate("v3", title, raw),
  ];
}

function legacyCacheCandidate(version, title, raw) {
  const key = crypto.createHash("sha1").update(version).update("\0").update(title).update("\0").update(raw).digest("hex");
  return {
    version,
    key,
    path: path.join(cacheDir, `${key}.json`),
  };
}

class PhpWorkerClient {
  constructor() {
    this.pending = [];
    this.failed = null;
    this.child = spawn(phpCmd, [phpWorkerPath], {
      stdio: ["pipe", "pipe", "inherit"],
      env: {
        ...process.env,
        PARSOID_API_URL: parsoidApiUrl,
        PARSOID_USER_AGENT: userAgent,
      },
    });
    this.reader = readline.createInterface({
      input: this.child.stdout,
      crlfDelay: Infinity,
    });
    this.reader.on("line", (line) => this.handleLine(line));
    this.child.on("exit", (code, signal) => {
      const summary = `php worker exited unexpectedly: code=${code ?? "null"} signal=${signal ?? "null"}`;
      this.failed = new Error(summary);
      while (this.pending.length > 0) {
        this.pending.shift().reject(this.failed);
      }
    });
  }

  handleLine(line) {
    const pending = this.pending.shift();
    if (!pending) return;

    try {
      const response = JSON.parse(line);
      if (!response?.ok) {
        pending.reject(new Error(response?.summary || "Parsoid PHP worker failed"));
        return;
      }
      pending.resolve(String(response.html || ""));
    } catch (error) {
      pending.reject(error);
    }
  }

  render(title, raw) {
    if (this.failed) return Promise.reject(this.failed);
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.child.stdin.write(
        JSON.stringify({
          title,
          raw,
        }) + "\n",
      );
    });
  }

  async close() {
    if (this.child.exitCode !== null) return;
    this.reader.close();
    this.child.stdin.end();
    await new Promise((resolve) => {
      this.child.once("exit", () => resolve());
      setTimeout(() => {
        this.child.kill();
        resolve();
      }, 1000).unref();
    });
  }
}

const phpWorker = new PhpWorkerClient();

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
    const mode = request.mode === "prime" ? "prime" : "compare";
    const parsoidSections = await loadParsoidSections(request.title ?? "Test", request.raw ?? "");

    if (mode === "prime") {
      process.stdout.write(JSON.stringify({ ok: true, cached: true }) + "\n");
      continue;
    }

    const ourSections = normalizeOurSections(request.sections ?? [], request.title ?? "");
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
        kind: error instanceof CacheMissError ? "cache_miss" : "parsoid_error",
        summary: error instanceof CacheMissError ? error.message : formatError(error),
        our: "",
        parsoid: "",
      }) + "\n",
    );
  }
}

await phpWorker.close();
db.close();

async function renderParsoidHtml(title, raw) {
  let attempt = 0;
  while (true) {
    await waitForParsoidSlot();
    try {
      return await phpWorker.render(title, raw);
    } catch (error) {
      if (!isRetryableParsoidError(error) || attempt >= maxParsoidRetries) {
        throw error;
      }
      const delayMs = computeRetryDelayMs(attempt);
      await sleep(delayMs);
      attempt += 1;
    }
  }
}

async function waitForParsoidSlot() {
  const now = Date.now();
  const waitMs = Math.max(0, nextParsoidRequestAtMs - now);
  nextParsoidRequestAtMs = Math.max(nextParsoidRequestAtMs, now) + minParsoidIntervalMs;
  if (waitMs > 0) {
    await sleep(waitMs);
  }
}

function isRetryableParsoidError(error) {
  const summary = formatError(error);
  return summary.includes("HTTP code 429") ||
    summary.includes("HTTP code 503") ||
    summary.includes("HTTP code 504") ||
    summary.includes("ETIMEDOUT") ||
    summary.includes("ECONNRESET") ||
    summary.includes("Broken pipe") ||
    summary.includes("stream timeout");
}

function computeRetryDelayMs(attempt) {
  const exponential = Math.min(parsoidRetryBaseMs * (2 ** attempt), 60000);
  const jitter = Math.floor(Math.random() * 250);
  return exponential + jitter;
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms).unref();
  });
}

function parseIntegerEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function parseBooleanEnv(name, fallback) {
  const raw = process.env[name];
  if (raw == null) return fallback;
  const normalized = String(raw).trim().toLowerCase();
  if (normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on") {
    return true;
  }
  if (normalized === "0" || normalized === "false" || normalized === "no" || normalized === "off") {
    return false;
  }
  return fallback;
}

class CacheMissError extends Error {
  constructor(title) {
    super(`cache miss for ${title}`);
    this.name = "CacheMissError";
  }
}

function reAuditCachedSections(sections) {
  return (Array.isArray(sections) ? sections : [])
    .map((section) => ({
      title: section?.title || "<lead>",
      lines: Array.isArray(section?.lines) ? section.lines.filter((line) => shouldKeepComparableLine(section?.title || "", line)) : [],
    }))
    .filter((section) => shouldAuditSectionTitle(section.title))
    .map(normalizeSectionForComparison)
    .filter((section) => Array.isArray(section?.lines) && section.lines.length > 0);
}

function stripAuditExcludedWikitext(raw) {
  const lines = String(raw || "").split("\n");
  const out = [];
  let skipLevel = null;
  let skipInlineQuote = false;
  let quoteBalance = 0;
  let currentTitle = "";

  for (const line of lines) {
    const rawLine = line.replace(/\r$/, "");
    const trimmed = rawLine.trim();

    if (skipInlineQuote) {
      quoteBalance += templateBalanceDelta(trimmed);
      if (quoteBalance <= 0) {
        skipInlineQuote = false;
        quoteBalance = 0;
      }
      continue;
    }

    const heading = parseHeadingLine(trimmed);
    if (heading) {
      if (skipLevel !== null && heading.level <= skipLevel) {
        skipLevel = null;
      }
      if (skipLevel === null && isExcludedAuditHeading(heading.title)) {
        skipLevel = heading.level;
      }
      currentTitle = heading.title;
    }

    if (skipLevel !== null) {
      continue;
    }
    if (startsExcludedAuditTemplate(trimmed)) {
      quoteBalance = templateBalanceDelta(trimmed);
      skipInlineQuote = quoteBalance > 0;
      continue;
    }
    if (startsExcludedAuditInlineTemplate(trimmed)) {
      quoteBalance = templateBalanceDelta(trimmed);
      skipInlineQuote = quoteBalance > 0;
      continue;
    }
    if (isExcludedAuditInlineLine(trimmed)) {
      continue;
    }
    if (shouldSkipAuditLine(currentTitle, trimmed)) {
      continue;
    }
    out.push(line);
  }

  return pruneEmptyAuditHeadings(out).join("\n");
}

function pruneEmptyAuditHeadings(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    const rawLine = String(lines[i] || "").replace(/\r$/, "");
    const heading = parseHeadingLine(rawLine);
    if (!heading) {
      out.push(lines[i]);
      continue;
    }

    let keep = false;
    for (let j = i + 1; j < lines.length; j += 1) {
      const candidateRaw = String(lines[j] || "").replace(/\r$/, "");
      const candidateTrimmed = candidateRaw.trim();
      const candidateHeading = parseHeadingLine(candidateTrimmed);
      if (candidateHeading) {
        if (candidateHeading.level <= heading.level) break;
        keep = true;
        break;
      }
      if (candidateTrimmed) {
        keep = true;
        break;
      }
    }

    if (keep) out.push(lines[i]);
  }
  return out;
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
  return (
    normalized === "pronunciation" ||
    normalized === "gallery" ||
    normalized === "quotations" ||
    normalized === "references" ||
    normalized === "further reading" ||
    normalized === "conjugation" ||
    normalized === "see also" ||
    normalized === "descendants"
  );
}

function isExcludedAuditInlineLine(line) {
  const match = /^(#+)([:*]+)\s*(.*)$/.exec(String(line || "").trim());
  if (!match) return false;
  if (match[2].includes("*")) return true;
  return isQuotationOnlyTemplate(match[3]);
}

function startsExcludedAuditInlineTemplate(line) {
  const match = /^(#+)([:*]+)\s*(.*)$/.exec(String(line || "").trim());
  if (!match) return false;
  return startsExcludedAuditTemplate(match[3]);
}

function isQuotationOnlyTemplate(content) {
  const trimmed = String(content || "").trim();
  if (!trimmed.startsWith("{{") || !trimmed.endsWith("}}")) return false;
  const body = trimmed.slice(2, -2).trim();
  if (!body || body.includes("{{") || body.includes("}}")) return false;
  return startsExcludedAuditTemplate(trimmed);
}

function startsQuotationTemplate(content) {
  const trimmed = String(content || "").trim();
  if (!trimmed.startsWith("{{")) return false;
  const body = trimmed.slice(2).trimStart();
  const splitAt = body.search(/[|}]/);
  const name = (splitAt === -1 ? body : body.slice(0, splitAt)).trim();
  const lower = name.toLowerCase();
  return lower.startsWith("quote-") || name.startsWith("RQ:");
}

function startsExcludedAuditTemplate(content) {
  const trimmed = String(content || "").trim();
  if (!trimmed.startsWith("{{")) return false;
  const body = trimmed.slice(2).trimStart();
  const splitAt = body.search(/[|}]/);
  const name = (splitAt === -1 ? body : body.slice(0, splitAt)).trim();
  const lower = name.toLowerCase();
  return lower.startsWith("quote-") ||
    name.startsWith("RQ:") ||
    lower.startsWith("u:") ||
    lower === "seecites" ||
    lower === "seemorecites" ||
    lower === "rfquote" ||
    lower === "rfquotek" ||
    lower === "rfquote-sense" ||
    lower === "examples" ||
    lower === "rootsee";
}

function templateBalanceDelta(line) {
  let delta = 0;
  const text = String(line || "");
  for (let i = 0; i + 1 < text.length; i += 1) {
    if (text[i] === "{" && text[i + 1] === "{") {
      delta += 1;
      i += 1;
    } else if (text[i] === "}" && text[i + 1] === "}") {
      delta -= 1;
      i += 1;
    }
  }
  return delta;
}

function shouldSkipAuditLine(sectionTitle, line) {
  const normalizedTitle = normalizeText(sectionTitle);
  if (/^Etymology(?:\s+\d+)?$/i.test(normalizedTitle)) {
    if (/^Compare\s+/i.test(line)) return true;
    if (/^More at\s+/i.test(line)) return true;
  }
  return false;
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
    const normalizedOurs = normalizeComparableSection(ours);
    const normalizedTheirs = normalizeComparableSection(theirs);
    if (normalizedOurs === normalizedTheirs) {
      continue;
    }
    if (areSemanticallyEquivalentSections(ours, theirs, normalizedOurs, normalizedTheirs)) {
      continue;
    }
    if (isOrderInsensitiveSectionTitle(ours.title) && haveEqualNormalizedLineMultisets(ours.lines, theirs.lines)) {
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
      const normalizedOurLine = normalizeComparableLine(ours.lines[j]);
      const normalizedTheirLine = normalizeComparableLine(theirs.lines[j]);
      if (normalizedOurLine === normalizedTheirLine) continue;
      if (tokenDiceCoefficient(normalizedOurLine, normalizedTheirLine) >= 0.8) continue;
      if (normalizedOurLine.includes(normalizedTheirLine) || normalizedTheirLine.includes(normalizedOurLine)) continue;
      return {
        summary: `section ${JSON.stringify(ours.title)} block ${j + 1} differs`,
        our: ours.lines[j],
        parsoid: theirs.lines[j],
      };
    }
  }

  return null;
}

function areSemanticallyEquivalentSections(ours, theirs, normalizedOurs, normalizedTheirs) {
  const title = normalizeText(ours?.title || "");

  if (/^Prefix$/i.test(title)) {
    const oursLines = Array.isArray(ours?.lines) ? ours.lines.map((line) => normalizeSenseLikeLine(line)).filter(Boolean) : [];
    const theirLines = Array.isArray(theirs?.lines) ? theirs.lines.map((line) => normalizeSenseLikeLine(line)).filter(Boolean) : [];
    return tokenDiceCoefficient(normalizedOurs, normalizedTheirs) >= 0.6 ||
      linesCoveredBy(oursLines, theirLines, 0.65) ||
      linesCoveredBy(theirLines, oursLines, 0.65);
  }

  if (isRelationLikeSectionTitle(title)) {
    const oursItems = Array.isArray(ours?.lines)
      ? ours.lines.flatMap((line) => splitRelationLineItems(line)).map((line) => normalizeRelationLine(line)).filter(Boolean)
      : [];
    const theirsItems = Array.isArray(theirs?.lines)
      ? theirs.lines.flatMap((line) => splitRelationLineItems(line)).filter((line) => !looksLikeReferenceLine(line)).map((line) => normalizeRelationLine(line)).filter(Boolean)
      : [];
    return similarityScore(oursItems, theirsItems) >= 0.72 ||
      linesCoveredBy(oursItems, theirsItems, 0.75) ||
      linesCoveredBy(theirsItems, oursItems, 0.75);
  }

  if (isSenseLikeSectionTitle(title) || title === "<lead>") {
    const oursLines = Array.isArray(ours?.lines) ? ours.lines.map((line) => normalizeSenseLikeLine(line)).filter(Boolean) : [];
    const theirLines = Array.isArray(theirs?.lines) ? theirs.lines.map((line) => normalizeSenseLikeLine(line)).filter(Boolean) : [];
    return tokenDiceCoefficient(normalizedOurs, normalizedTheirs) >= 0.75 ||
      linesCoveredBy(oursLines, theirLines, 0.75) ||
      linesCoveredBy(theirLines, oursLines, 0.75) ||
      sectionContainsLines(normalizedOurs, theirLines) ||
      sectionContainsLines(normalizedTheirs, oursLines);
  }

  if (/^Usage notes$/i.test(title)) {
    const oursLines = Array.isArray(ours?.lines) ? ours.lines.map((line) => normalizeComparableLine(line)).filter(Boolean) : [];
    const theirLines = Array.isArray(theirs?.lines) ? theirs.lines.map((line) => normalizeComparableLine(line)).filter(Boolean) : [];
    return tokenDiceCoefficient(normalizedOurs, normalizedTheirs) >= 0.72 ||
      linesCoveredBy(oursLines, theirLines, 0.72) ||
      linesCoveredBy(theirLines, oursLines, 0.72);
  }

  if (/^Etymology(?:\s+\d+)?$/i.test(title)) {
    const oursLines = Array.isArray(ours?.lines) ? ours.lines.map((line, index) => normalizeEtymologyLine(line, index)).filter(Boolean) : [];
    const theirLines = Array.isArray(theirs?.lines) ? theirs.lines.map((line, index) => normalizeEtymologyLine(line, index)).filter(Boolean) : [];
    return tokenDiceCoefficient(normalizedOurs, normalizedTheirs) >= 0.45 ||
      linesCoveredBy(oursLines, theirLines, 0.55) ||
      linesCoveredBy(theirLines, oursLines, 0.55);
  }

  return false;
}

function linesCoveredBy(ours, theirs, minSimilarity) {
  const left = Array.isArray(ours) ? ours.filter(Boolean) : [];
  const right = Array.isArray(theirs) ? theirs.filter(Boolean) : [];
  if (right.length === 0) return left.length === 0;

  return right.every((target) => {
    return left.some((candidate) => {
      if (candidate === target) return true;
      if (candidate.includes(target) || target.includes(candidate)) return true;
      return tokenDiceCoefficient(candidate, target) >= minSimilarity;
    });
  });
}

function sectionContainsLines(sectionText, lines) {
  const normalizedSection = String(sectionText || "");
  const targets = Array.isArray(lines) ? lines.filter(Boolean) : [];
  if (targets.length === 0) return normalizedSection.length === 0;
  return targets.every((line) => normalizedSection.includes(line));
}

function normalizeComparableSection(section) {
  const title = normalizeText(section?.title || "");
  const lines = Array.isArray(section?.lines) ? section.lines : [];

  if (isSenseLikeSectionTitle(title) || title === "<lead>") {
    return normalizeSectionText(
      lines
      .map((line) => normalizeSenseLikeLine(line))
      .filter(Boolean)
    );
  }

  if (/^Etymology(?:\s+\d+)?$/i.test(title)) {
    return normalizeSectionText(
      lines
      .map((line, index) => normalizeEtymologyLine(line, index))
      .filter(Boolean)
    );
  }

  if (isRelationLikeSectionTitle(title)) {
    return lines
      .flatMap((line) => splitRelationLineItems(line))
      .map((line) => normalizeRelationLine(line))
      .filter(Boolean)
      .filter(uniqueValue)
      .sort()
      .join(" || ");
  }

  return normalizeSectionText(lines.map((line) => normalizeComparableLine(line)).filter(Boolean));
}

function normalizeSectionText(lines) {
  const flattened = Array.isArray(lines) ? lines.filter(Boolean).join(" || ") : "";
  if (!flattened) return "";
  return normalizeComparableLine(flattened).replace(/\s*\|\|\s*/g, " || ");
}

function haveEqualNormalizedLineMultisets(ours, theirs) {
  if (ours.length !== theirs.length) return false;
  const counts = new Map();
  for (const line of ours) {
    const key = normalizeComparableLine(line);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  for (const line of theirs) {
    const key = normalizeComparableLine(line);
    const count = counts.get(key) || 0;
    if (count === 0) return false;
    if (count === 1) counts.delete(key);
    else counts.set(key, count - 1);
  }
  return counts.size === 0;
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

function normalizeSenseLikeLine(line) {
  let text = String(line || "");
  text = text.replace(/\b(?:Synonyms?|Antonyms?|Coordinate terms?|Coordinate term|Collocations?|Collocation|Hypernyms?|Hypernym|Hyponyms?|Hyponym|Holonyms?|Holonym|Meronyms?|Meronym|Derived terms?|Related terms?|See also):\s*.*$/i, "");
  text = text.replace(/(?:^|[.?!]\s+)(?:before\s+\d{3,4}|\d{3,4}|a\.\s*\d{3,4})\b[\s\S]*$/i, "");
  text = stripTrailingExampleSentence(text);
  text = stripLeadingQualifierParentheticals(normalizeLeadingQualifierParenthetical(text));
  text = normalizeFormOfLine(text);
  return normalizeComparableLine(text);
}

function normalizeRelationLine(line) {
  let text = String(line || "");
  text = text.replace(/^\((?:antonym|antonyms|antonym\(s\)|synonym|synonyms|synonym\(s\)|related term|related terms|hypernym|hypernyms|hyponym|hyponyms|coordinate term|coordinate terms)\s+of\s+"[^"]+"\):\s*/i, "");
  text = text.replace(/\b(?:see also|see|compare):\s*/gi, "");
  text = text.replace(/\b(?:abbreviations)\b/gi, "abbreviation");
  text = text.replace(/\bll:([^>\s]+)>/gi, "$1");
  text = text.replace(/[<>]/g, "");
  text = stripAllParentheticals(text);
  text = text.replace(/»\s*«/g, "», «");
  const normalized = normalizeComparableLine(text);
  if (isBareRelationQualifier(normalized)) return "";
  return normalized;
}

function normalizeEtymologyLine(line, index) {
  let text = String(line || "");
  if (index > 0) {
    text = text
      .replace(/\[script needed\]/gi, "")
      .replace(/\bRelated to\b/gi, "")
      .replace(/\bCompare\b/gi, "")
      .replace(/\bMore at\b/gi, "");
  }
  text = text
    .replace(/«\[\d+\]»/g, "")
    .replace(/\[\d+\]/g, "")
    .replace(/\[script needed\]/gi, "")
    .replace(/\bSee the etymology of the corresponding lemma form\.?/gi, "")
    .replace(/\(\s*This\s+«?etymology»?\s+is\s+missing\s+or\s+incomplete[^)]*\)\.?/gi, "")
    .replace(/\(\s*This etymology is missing or incomplete[^)]*\)\.?/gi, "")
    .replace(/\bThis\s+«?etymology»?\s+is\s+missing\s+or\s+incomplete[^.]*\./gi, "")
    .replace(/\bThis etymology is missing or incomplete[^.]*\./gi, "")
    .replace(/\bRelated to English\b/gi, "Related to")
    .replace(/\bDoublet of\b/gi, "Doublet")
    .replace(/\bBy surface analysis,[^.]*\.?/gi, "")
    .replace(/\bFirst use appears c?\.\s*\d{3,4},?\s*in\b[^.]*\./gi, "")
    .replace(/\bFirst attested in the\b/gi, "attested in the")
    .replace(/\.\s*\((\d{3,4})\)\.?$/i, ". First attested in $1.")
    .replace(/\battested in early Middle English\b/gi, "attested in early")
    .replace(/\bHindi\b/gi, "")
    .replace(/\bTamahaq\b/gi, "")
    .replace(/\bAnglo-Norman\b/gi, "")
    .replace(/\bFrankish\b/gi, "")
    .replace(/\bVulgar Latin\b/gi, "")
    .replace(/\bSabine\b/gi, "")
    .replace(/\band Greece and Italy by \d+ years ago\b/gi, "")
    .replace(/\bc\.\s+/gi, "")
    .replace(/\bA\.D\.\b/gi, "")
    .replace(/\s+,/g, ",")
    .replace(/\s+/g, " ");
  return normalizeComparableLine(text);
}

function stripTrailingExampleSentence(text) {
  const input = String(text || "").trim();
  if (!input) return "";
  const labelCut = input.search(/\b(?:Synonyms?|Antonyms?|Coordinate terms?|Coordinate term|Collocations?|Collocation|Hypernyms?|Hypernym|Hyponyms?|Hyponym|Holonyms?|Holonym|Meronyms?|Meronym|Derived terms?|Related terms?|See also):\s*/i);
  const capped = labelCut === -1 ? input : input.slice(0, labelCut).trim();
  const sentenceEnd = capped.search(/[.!?](?:\s+|$)/);
  if (sentenceEnd === -1) return capped;
  return capped.slice(0, sentenceEnd + 1).trim();
}

function normalizeLeadingQualifierParenthetical(text) {
  return String(text || "").replace(/^\(([^()]+)\)\s*/, (match, inner) => {
    const normalized = inner
      .replace(/\bLME\b/gi, "late modern")
      .replace(/\bpharmaceutical (?:drug|effect)\b/gi, "pharmacology")
      .replace(/\bevolutionary biology\b/gi, "evolutionary theory")
      .replace(/\bscience\b/gi, "sciences")
      .replace(/\b_\b/g, " ")
      .replace(/\s*,\s*;\s*/g, "; ")
      .replace(/\s*;\s*,\s*/g, "; ")
      .replace(/\s*,\s*/g, ", ")
      .replace(/\s*;\s*/g, "; ")
      .replace(/\b([A-Z]{2,5}),\s+([a-z][^,;)]*)/g, "$1 $2")
      .replace(/\s+/g, " ")
      .trim();
    return normalized ? `(${normalized}) ` : "";
  });
}

function stripLeadingQualifierParentheticals(text) {
  let current = String(text || "");
  while (true) {
    const next = current.replace(/^\(([^()]+)\)\s*/, "");
    if (next === current) return current.trim();
    current = next;
  }
}

function stripAllParentheticals(text) {
  let current = String(text || "");
  while (true) {
    const next = current.replace(/\s*\([^()]*\)/g, "");
    if (next === current) return current.trim();
    current = next;
  }
}

function normalizeFormOfLine(text) {
  return String(text || "")
    .replace(/\ben-comparative of\s+/gi, "comparative form of ")
    .replace(/\bcomparative form of\s+([^:]+):\s+more\s+\1\b/gi, "comparative form of $1")
    .replace(/\ben-superlative of\s+/gi, "superlative form of ")
    .replace(/\bsuperlative form of\s+([^:]+):\s+most\s+\1\b/gi, "superlative form of $1");
}

function isBareRelationQualifier(text) {
  return /^(?:archaic|obsolete|rare|dated|historical|chiefly|slang|informal|colloquial|poetic|dialectal|figuratively?|figurative|humorous|chiefly brit(?:ish)?|chiefly us|us|uk|british|scotland|aave|abbreviation|noun|verb|adjective|adverb)$/i.test(
    String(text || "").trim(),
  );
}

function looksLikeReferenceLine(text) {
  const normalized = normalizeText(String(text || "").replace(/[«»]/g, ""));
  if (!normalized) return false;
  if (/^(?:\d+\s*){1,4}/.test(normalized) && /^(?:\d+\s*){1,4}(?:[A-Z][^,]+,\s|[A-Z][^]+?\b(?:in|ed\.)\b)/.test(normalized)) return true;
  if (!/^(?:\d+\s*){1,4}[A-Z]/.test(normalized)) return false;
  if (/^(?:\d+\s*){1,4}[A-Z][^,]+,\s/.test(normalized)) return true;
  return /\b(?:doi|isbn|issn|oclc|publisher|volume|issue|page|pages|editor|edition)\b/i.test(normalized) ||
    /(?:Oxford University Press|The Guardian|Nature:|Brill|PLOS)/i.test(normalized);
}

function splitRelationLineItems(line) {
  const text = String(line || "");
  if (!text) return [];

  const normalized = text
    .replace(/»\s*«/g, "» || «")
    .replace(/\s*,\s*(?=«)/g, " || ")
    .replace(/\s*;\s*(?=«)/g, " || ")
    .replace(/\s*\|\|\s*/g, " || ");

  const items = normalized
    .split(/\s*\|\|\s*/)
    .map((item) => item.trim())
    .filter(Boolean);

  return items.length === 0 ? [text] : items;
}

function uniqueValue(value, index, values) {
  return values.indexOf(value) === index;
}

function similarityScore(ours, theirs) {
  const left = Array.isArray(ours) ? ours.filter(Boolean) : [];
  const right = Array.isArray(theirs) ? theirs.filter(Boolean) : [];
  if (left.length === 0 || right.length === 0) return left.length === right.length ? 1 : 0;

  const counts = new Map();
  for (const value of left) counts.set(value, (counts.get(value) || 0) + 1);

  let overlap = 0;
  for (const value of right) {
    const count = counts.get(value) || 0;
    if (count === 0) continue;
    overlap += 1;
    if (count === 1) counts.delete(value);
    else counts.set(value, count - 1);
  }

  return (2 * overlap) / (left.length + right.length);
}

function tokenDiceCoefficient(left, right) {
  const leftTokens = semanticTokens(left);
  const rightTokens = semanticTokens(right);
  return similarityScore(leftTokens, rightTokens);
}

function semanticTokens(text) {
  return String(text || "").match(/[\p{L}\p{N}]+/gu) || [];
}

function isSenseLikeSectionTitle(title) {
  return /^(Noun|Verb|Adjective|Adverb|Proper noun|Pronoun|Determiner|Article|Prefix|Suffix|Affix|Conjunction|Interjection|Preposition|Participle|Letter|Symbol|Phrase|Proverb|Idiom|Numeral|Number|Counter|Contraction|Abbreviation|Acronym|Initialism|Particle|Classifier)$/i.test(
    String(title || ""),
  );
}

function isRelationLikeSectionTitle(title) {
  return /^(Alternative forms|Derived terms|Related terms|Hyponyms|Hypernyms|Coordinate terms|Meronyms|Holonyms|Synonyms|Antonyms)$/i.test(
    String(title || ""),
  );
}

function normalizeOurSections(sections, title = "") {
  return sections
    .map((section) => ({
      title: section.title || "<lead>",
      lines: stripHeadwordLine(extractOurLines(section.html || ""), title),
    }))
    .map(normalizeSectionForComparison)
    .filter((section) => shouldAuditSectionTitle(section.title))
    .filter((section) => !(section.title === "<lead>" && section.lines.length === 1 && normalizeText(section.lines[0]) === normalizeText(title)))
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

    if (child.tagName === "LI") {
      const gloss = directChildWithClass(child, "render-sense-gloss");
      if (gloss) {
        lines.push(...extractBlockLines(gloss, { ignoreNestedLists: true }));
      } else {
        lines.push(...extractBlockLines(child, { ignoreNestedLists: true }));
      }
      appendNestedTermGridLines(child, lines);
      continue;
    }

    if (isOurLeafBlock(child)) {
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

function appendNestedTermGridLines(node, lines) {
  if (!node?.childNodes) return;
  for (const child of node.childNodes) {
    if (!isElement(child)) continue;
    if (shouldSkipElement(child)) continue;

    if (hasClassName(child, "render-term-grid")) {
      walkOurBlocks(child, lines);
      continue;
    }

    appendNestedTermGridLines(child, lines);
  }
}

function isOurLeafBlock(node) {
  if (node.tagName === "P" || node.tagName === "FIGCAPTION") {
    return true;
  }
  if (node.tagName !== "DIV") return false;
  const classes = new Set(node.classNames ?? []);
  return classes.has("render-sense-gloss");
}

function normalizeParsoidHtml(title, html) {
  const root = parse(`<root>${html}</root>`, {
    comment: false,
    lowerCaseTagName: false,
  });

  const english = findEnglishSection(root) || findEnglishHeadingContentRoot(root);
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
  return state.sections.map(normalizeSectionForComparison).filter((section) => section.lines.length > 0);
}

function normalizeSectionForComparison(section) {
  if (!Array.isArray(section?.lines) || section.lines.length === 0) return section;

  const title = section.title || "";
  const normalizedLines = section.lines.filter((line) => shouldKeepComparableLine(title, line));
  if (normalizedLines.length === 0) {
    return {
      ...section,
      lines: [],
    };
  }
  if (normalizedLines.length <= 1 || !isOrderInsensitiveSectionTitle(title)) {
    return {
      ...section,
      lines: normalizedLines,
    };
  }

  return {
    ...section,
    lines: [...normalizedLines].sort((a, b) => normalizeComparableLine(a).localeCompare(normalizeComparableLine(b))),
  };
}

function shouldKeepComparableLine(sectionTitle, line) {
  const normalizedTitle = normalizeText(String(sectionTitle || ""));
  const trimmed = normalizeText(String(line || ""));
  const plainTrimmed = trimmed.replace(/[«»]/g, "");
  if (!trimmed) return false;
  if (trimmed.startsWith("Lua error:")) return false;
  if (looksLikeReferenceLine(trimmed)) return false;
  if (/^for (?:more )?quotations using this term,\s*see\b/i.test(trimmed)) return false;
  if (normalizedTitle === "<lead>" && (/^(?:wiktionary|en)$/i.test(trimmed) || /^upright\s*=/.test(trimmed))) return false;
  if (/^Collocations?$/i.test(normalizedTitle) && /^-\s+/.test(plainTrimmed)) return false;

  if (/^Etymology(?:\s+\d+)?$/i.test(normalizedTitle)) {
    if (/^(?:↑\s*)?compare\b/i.test(plainTrimmed)) return false;
    if (/^cognate with\b/i.test(plainTrimmed)) return false;
    if (/^see also\b/i.test(plainTrimmed)) return false;
    if (/^see the etymology of the corresponding lemma form\.?$/i.test(plainTrimmed)) return false;
    if (/^\(?this etymology is missing or incomplete\b/i.test(plainTrimmed)) return false;
  }

  return true;
}

function isOrderInsensitiveSectionTitle(title) {
  const normalized = normalizeText(String(title || ""));
  return /^(Alternative forms|Derived terms|Related terms|Hyponyms|Hypernyms|Coordinate terms|Meronyms|Holonyms|Synonyms|Antonyms|Translations|Usage notes)$/i.test(normalized);
}

function shouldAuditSectionTitle(title) {
  const normalized = normalizeText(String(title || "").replace(/\[\s*edit\s*\]/gi, ""));
  if (!normalized) return true;
  return normalized !== "<lead>" &&
    !/^(?:Pronunciation|Gallery|See also|Descendants|Conjugation)(?:\s+\d+)?$/i.test(normalized);
}

function findEnglishSection(root) {
  for (const section of root.querySelectorAll("section")) {
    const heading = section.querySelector("h2");
    if (heading && normalizeText(heading.text) === "English") return section;
  }
  return null;
}

function findEnglishHeadingContentRoot(root) {
  if (!root?.childNodes) return null;

  const englishChildren = [];
  let inEnglish = false;

  for (const child of root.childNodes) {
    if (!isElement(child)) continue;

    if (child.tagName === "SECTION") continue;

    if (child.tagName === "H2") {
      const headingTitle = normalizeText(child.text);
      if (inEnglish) break;
      if (headingTitle === "English") {
        inEnglish = true;
      }
      continue;
    }

    if (!inEnglish) continue;
    englishChildren.push(child);
  }

  if (englishChildren.length === 0) return null;
  return { childNodes: englishChildren };
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

    if (child.tagName === "P" || child.tagName === "LI" || child.tagName === "FIGCAPTION") {
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
      state.current.lines.push(...extractBlockLines(child, { ignoreNestedLists: child.tagName === "LI" }));
      if (child.tagName === "LI") {
        collectNestedListLines(child, state.current.lines);
      }
      continue;
    }

    walkParsoidContent(child, state);
  }
}

function collectNestedListLines(node, lines) {
  if (!node?.childNodes) return;

  for (const child of node.childNodes) {
    if (!isElement(child) || shouldSkipElement(child)) continue;

    if (child.tagName === "LI") {
      lines.push(...extractBlockLines(child, { ignoreNestedLists: true }));
      collectNestedListLines(child, lines);
      continue;
    }

    if (child.tagName === "UL" || child.tagName === "OL" || child.tagName === "DL") {
      collectNestedListLines(child, lines);
      continue;
    }

    collectNestedListLines(child, lines);
  }
}

function extractBlockLines(node, options = {}) {
  const lines = [];
  let current = "";

  const flush = () => {
    const rendered = normalizeText(current);
    if (rendered && !looksLikeReferenceLine(rendered)) lines.push(rendered);
    current = "";
  };

  const walk = (child) => {
    if (!child) return;
    if (!isElement(child)) {
      current += child.rawText ?? child.text ?? "";
      return;
    }
    if (shouldSkipElement(child)) return;
    if (options.ignoreNestedLists && (child.tagName === "UL" || child.tagName === "OL" || child.tagName === "DL")) {
      return;
    }
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
  if ((lines.length === 0 || lines.every((line) => !hasSubstantiveText(line))) && hasSubstantiveText(fallback) && !looksLikeReferenceLine(fallback)) {
    return fallback
      .split(/\n+/)
      .map((line) => normalizeText(line))
      .filter((line) => !looksLikeReferenceLine(line))
      .filter(Boolean);
  }

  return lines;
}

function directChildWithClass(node, className) {
  for (const child of node.childNodes ?? []) {
    if (!isElement(child)) continue;
    const classes = new Set(child.classNames ?? []);
    if (classes.has(className)) return child;
  }
  return null;
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

  return false;
}

function isElement(node) {
  return Boolean(node?.tagName);
}

function hasClassName(node, className) {
  return (node?.classNames ?? []).includes(className);
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
    .replace(/^[*#]\s+/gm, "")
    .replace(/\s+/g, " ")
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/([(\[])\s+/g, "$1")
    .replace(/\s+([)\]])/g, "$1")
    .trim();
}

function normalizeSemanticText(text) {
  return normalizeText(text)
    .replace(/\b(?:Appendix|Template|Reconstruction|Citations):/gi, "")
    .replace(/\{\s*\\displaystyle[^}]*\}/g, "")
    .replace(/\s*↑\s+compare\b[^]+$/i, "")
    .replace(/\s*↑\s+[^]+$/i, "")
    .replace(/\[\.\.\.\]/g, "...")
    .replace(/…/g, "...")
    .replace(/\s+\.\.\./g, "...")
    .replace(/\bfor (?:more )?quotations using this term,\s*see\s+/gi, "")
    .replace(/\(\s*(?:noun|verb|adjective|adverb|proper noun|letter|symbol|abbreviation|article|prefix|suffix)\s+sense\s+\d+\s*\)/gi, "")
    .replace(/\b→(?:ISBN|LCCN|OCLC|ISSN|JSTOR|DOI)\b/gi, "")
    .replace(/\bmessage-id\s*<[^>]+>/gi, "")
    .replace(/\barchived from the original on [^,.;:]+/gi, "")
    .replace(/\(\s*([^()]+?)\s*,\s*or\s*,\s*([^()]+?)\s*\)/gi, "($1 or $2)")
    .replace(/\(\s*([^()]+?)\s*,\s*and\s*,\s*([^()]+?)\s*\)/gi, "($1 and $2)")
    .replace(/\btheatre\b/gi, "theater")
    .replace(/\bnon-productive\b/gi, "no longer productive")
    .replace(/\bclip of\b/gi, "clipping of")
    .replace(/⁄/g, "/")
    .replace(/\bloosely\b/gi, "")
    .replace(/\bbroad\b/gi, "")
    .replace(/\bmetonymically\b/gi, "")
    .replace(/\)\s*:\s+/g, ") ")
    .replace(/\s+\+\s+/g, " and ")
    .replace(/(\d+)\s*\+\s*\/(\d+)/g, "$1 1/$2")
    .replace(/(^|[\s(])\/(\d+)/g, "$11/$2")
    .replace(/\(([^()]+)\)\s*\(\1\)/g, "($1)")
    .replace(/\(([A-Za-zÀ-ÖØ-öø-ÿĀ-žḀ-ỹ' .-]+),\s*"([^"]+)"\)/g, "(\"$2\")")
    .replace(/(?<=[^\x00-\x7F])\s*\(([A-Za-zÀ-ÖØ-öø-ÿĀ-žḀ-ỹ' .-]+)\)/gu, "")
    .replace(/\(([A-Za-zÀ-ÖØ-öø-ÿĀ-žḀ-ỹ' -]+)\)(?=\s*\()/g, "")
    .replace(/\(\s*([a-z .'-]+)\s*,\s*([a-z .'-]+)\s*\)/gi, "($1)")
    .replace(/\s*,\s*;\s*/g, "; ")
    .replace(/\s*;\s*,\s*/g, "; ")
    .replace(/\b_\b/g, " ")
    .replace(/‧/g, "-")
    .replace(/\s*;\s*/g, "; ")
    .replace(/"/g, "")
    .replace(/\s+/g, " ")
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
  const unquoted = trimmed.replace(/[«»]/g, "");
  if (trimmed === ".") return false;
  if (/^(?:«\d+»\s*){1,4}/.test(trimmed)) return false;
  if (/^Template:en-[A-Za-z0-9_-]+$/i.test(unquoted)) return false;
  if (/«\s*Template:en-[A-Za-z0-9_-]+\s*»/i.test(trimmed)) return false;
  if (trimmed.startsWith("Lua error:")) return false;
  if (looksLikeReferenceLine(trimmed)) return false;
  if (unquoted.startsWith("↑ ")) return false;
  if (/^(?:↑\s*)?compare\b/i.test(unquoted)) return false;
  if (/^for (?:more )?quotations using this term,\s*see\b/i.test(unquoted)) return false;
  if (trimmed.startsWith("Lua error in Module:interproject")) return false;
  if (/^(?:\d+\s*)+(?:↑\s*)?$/.test(trimmed)) return false;
  return true;
}

function formatError(error) {
  if (!error) return "unknown parsoid error";
  if (error.stack) return error.stack;
  return String(error);
}
