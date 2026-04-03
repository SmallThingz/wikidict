const decoder = new TextDecoder();

const HEADER_SIZE = 96;
const STRING_REF_SIZE = 8;
const RANGE_SIZE = 8;
const ENTRY_SIZE = 60;
const SECTION_SIZE = 24;
const SENSE_SIZE = 36;
const LOOKUP_SIZE = 24;

const LOOKUP_KIND_TITLE = 0;
const LOOKUP_KIND_ALTERNATIVE_FORM = 1;
const FLAG_ALIAS_ONLY = 1 << 0;

export type ApiSection = {
  group: string;
  title: string;
  body: string;
};

export type ApiSense = {
  group: string;
  pos: string;
  gloss: string;
  examples: string;
  depth: number;
};

export type ApiEntry = {
  word: string;
  normalized: string;
  aliasOnly: boolean;
  altForms: string[];
  canonicalTargets: string[];
  incomingAliases: string[];
  sections: ApiSection[];
  senses: ApiSense[];
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

type Header = {
  version: number;
  entryCount: number;
  stringListCount: number;
  sectionCount: number;
  senseCount: number;
  lookupCount: number;
  entriesOffset: number;
  stringListsOffset: number;
  sectionsOffset: number;
  sensesOffset: number;
  lookupsOffset: number;
  stringsOffset: number;
  stringsLen: number;
};

type StringRef = {
  offset: number;
  len: number;
};

type Range = {
  start: number;
  len: number;
};

type EntryRecord = {
  word: StringRef;
  normalized: StringRef;
  altForms: Range;
  canonicalTargets: Range;
  incomingAliases: Range;
  sections: Range;
  senses: Range;
  flags: number;
};

type SectionRecord = {
  group: StringRef;
  title: StringRef;
  body: StringRef;
};

type SenseRecord = {
  group: StringRef;
  pos: StringRef;
  gloss: StringRef;
  examples: StringRef;
  depth: number;
};

type LookupRecord = {
  key: StringRef;
  display: StringRef;
  entryIndex: number;
  kind: number;
};

export class BinaryDictionary {
  private constructor(
    private readonly bytes: Uint8Array,
    private readonly view: DataView,
    readonly path: string,
    readonly header: Header,
  ) {}

  static async open(path: string): Promise<BinaryDictionary> {
    const bytes = new Uint8Array(await Bun.file(path).arrayBuffer());
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const magic = decoder.decode(bytes.subarray(0, 8));
    if (magic !== "WIKDICT1") {
      throw new Error(`Invalid dictionary magic in ${path}`);
    }

    const header: Header = {
      version: view.getUint32(8, true),
      entryCount: view.getUint32(16, true),
      stringListCount: view.getUint32(20, true),
      sectionCount: view.getUint32(24, true),
      senseCount: view.getUint32(28, true),
      lookupCount: view.getUint32(32, true),
      entriesOffset: Number(view.getBigUint64(40, true)),
      stringListsOffset: Number(view.getBigUint64(48, true)),
      sectionsOffset: Number(view.getBigUint64(56, true)),
      sensesOffset: Number(view.getBigUint64(64, true)),
      lookupsOffset: Number(view.getBigUint64(72, true)),
      stringsOffset: Number(view.getBigUint64(80, true)),
      stringsLen: Number(view.getBigUint64(88, true)),
    };

    if (header.version !== 1) {
      throw new Error(`Unsupported dictionary version ${header.version}`);
    }

    return new BinaryDictionary(bytes, view, path, header);
  }

  lookup(term: string): ApiLookupHit[] {
    const normalized = this.normalize(term);
    if (!normalized) return [];

    const start = this.lowerBound(normalized);
    const results: ApiLookupHit[] = [];
    for (let index = start; index < this.header.lookupCount; index += 1) {
      const record = this.readLookup(index);
      const key = this.text(record.key);
      if (key !== normalized) break;
      results.push({
        matched: this.text(record.display),
        kind: this.lookupKind(record.kind),
        entry: this.serializeEntry(record.entryIndex),
      });
    }
    return results;
  }

  suggest(prefix: string, limit = 12): ApiSuggestion[] {
    const normalized = this.normalize(prefix);
    if (!normalized) return [];

    const seen = new Set<string>();
    const suggestions: ApiSuggestion[] = [];
    for (let index = this.lowerBound(normalized); index < this.header.lookupCount && suggestions.length < limit; index += 1) {
      const record = this.readLookup(index);
      const key = this.text(record.key);
      if (!key.startsWith(normalized)) break;

      const matched = this.text(record.display);
      const entry = this.serializeEntry(record.entryIndex);
      const dedupeKey = `${record.entryIndex}:${matched}:${record.kind}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);

      suggestions.push({
        matched,
        word: entry.word,
        kind: this.lookupKind(record.kind),
        aliasOnly: entry.aliasOnly,
        summary: entry.summary,
      });
    }
    return suggestions;
  }

  randomWord(): string {
    const index = Math.floor(Math.random() * this.header.entryCount);
    return this.text(this.readEntry(index).word);
  }

  stats() {
    return {
      path: this.path,
      entries: this.header.entryCount,
      stringLists: this.header.stringListCount,
      sections: this.header.sectionCount,
      senses: this.header.senseCount,
      lookups: this.header.lookupCount,
      stringsBytes: this.header.stringsLen,
    };
  }

  private serializeEntry(index: number): ApiEntry {
    const entry = this.readEntry(index);
    const altForms = this.readStringList(entry.altForms);
    const canonicalTargets = this.readStringList(entry.canonicalTargets);
    const incomingAliases = this.readStringList(entry.incomingAliases);
    const sections = this.readSections(entry.sections);
    const senses = this.readSenses(entry.senses);

    return {
      word: this.text(entry.word),
      normalized: this.text(entry.normalized),
      aliasOnly: (entry.flags & FLAG_ALIAS_ONLY) !== 0,
      altForms,
      canonicalTargets,
      incomingAliases,
      sections,
      senses,
      summary: senses[0]?.gloss ?? sections[0]?.body ?? "",
    };
  }

  private readSections(range: Range): ApiSection[] {
    const sections: ApiSection[] = [];
    for (let index = 0; index < range.len; index += 1) {
      const section = this.readSection(range.start + index);
      sections.push({
        group: this.text(section.group),
        title: this.text(section.title),
        body: this.text(section.body),
      });
    }
    return sections;
  }

  private readSenses(range: Range): ApiSense[] {
    const senses: ApiSense[] = [];
    for (let index = 0; index < range.len; index += 1) {
      const sense = this.readSense(range.start + index);
      senses.push({
        group: this.text(sense.group),
        pos: this.text(sense.pos),
        gloss: this.text(sense.gloss),
        examples: this.text(sense.examples),
        depth: sense.depth,
      });
    }
    return senses;
  }

  private readStringList(range: Range): string[] {
    const results: string[] = [];
    for (let index = 0; index < range.len; index += 1) {
      results.push(this.text(this.readStringRef(this.header.stringListsOffset + (range.start + index) * STRING_REF_SIZE)));
    }
    return results;
  }

  private readEntry(index: number): EntryRecord {
    const offset = this.header.entriesOffset + index * ENTRY_SIZE;
    return {
      word: this.readStringRef(offset),
      normalized: this.readStringRef(offset + 8),
      altForms: this.readRange(offset + 16),
      canonicalTargets: this.readRange(offset + 24),
      incomingAliases: this.readRange(offset + 32),
      sections: this.readRange(offset + 40),
      senses: this.readRange(offset + 48),
      flags: this.view.getUint32(offset + 56, true),
    };
  }

  private readSection(index: number): SectionRecord {
    const offset = this.header.sectionsOffset + index * SECTION_SIZE;
    return {
      group: this.readStringRef(offset),
      title: this.readStringRef(offset + 8),
      body: this.readStringRef(offset + 16),
    };
  }

  private readSense(index: number): SenseRecord {
    const offset = this.header.sensesOffset + index * SENSE_SIZE;
    return {
      group: this.readStringRef(offset),
      pos: this.readStringRef(offset + 8),
      gloss: this.readStringRef(offset + 16),
      examples: this.readStringRef(offset + 24),
      depth: this.view.getUint16(offset + 32, true),
    };
  }

  private readLookup(index: number): LookupRecord {
    const offset = this.header.lookupsOffset + index * LOOKUP_SIZE;
    return {
      key: this.readStringRef(offset),
      display: this.readStringRef(offset + 8),
      entryIndex: this.view.getUint32(offset + 16, true),
      kind: this.view.getUint8(offset + 20),
    };
  }

  private readStringRef(offset: number): StringRef {
    return {
      offset: this.view.getUint32(offset, true),
      len: this.view.getUint32(offset + 4, true),
    };
  }

  private readRange(offset: number): Range {
    return {
      start: this.view.getUint32(offset, true),
      len: this.view.getUint32(offset + 4, true),
    };
  }

  private text(ref: StringRef): string {
    if (ref.len === 0) return "";
    const start = this.header.stringsOffset + ref.offset;
    return decoder.decode(this.bytes.subarray(start, start + ref.len));
  }

  private lookupKind(kind: number): "title" | "alternative_form" {
    return kind === LOOKUP_KIND_ALTERNATIVE_FORM ? "alternative_form" : "title";
  }

  private lowerBound(key: string): number {
    let low = 0;
    let high = this.header.lookupCount;
    while (low < high) {
      const mid = low + ((high - low) >> 1);
      const midKey = this.text(this.readLookup(mid).key);
      if (midKey < key) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  private normalize(term: string): string {
    return term
      .trim()
      .replace(/[_\s]+/g, " ")
      .toLowerCase();
  }
}
