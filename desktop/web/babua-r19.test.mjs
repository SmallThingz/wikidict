import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {dictionaryBlob} from './alias-fixtures.mjs';
import {buildIndex, decode, RawSource} from './blob.js';
import {validateContainerBlock, validateDescriptionBody} from './validate.js';
import {openSource} from './xz.js';

const directory = new URL('./testdata/babua/', import.meta.url);
const modelOptions = {containerFonts: true, positioned: true};
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const indexRaw = bytes => buildIndex(new RawSource(new Blob([bytes])));

async function member(name, size, memberSHA, offset, length, payloadSHA) {
  const bytes = await readFile(new URL(name, directory));
  assert.deepEqual([bytes.length, sha256(bytes)], [size, memberSHA]);
  const source = await openSource(new Blob([bytes]));
  const {metadata, rows} = await buildIndex(source);
  assert.deepEqual(rows.map(row => [row.title, row.offset, row.length]), [['babua', offset, length]]);
  const raw = Buffer.from(await source.read(0, source.size));
  const payload = raw.subarray(offset, offset + length);
  assert.equal(sha256(payload), payloadSHA);
  return {raw, payload, offset, context: {...metadata, title: 'babua', source_edition: 'idwiktionary'}};
}

const original = await member('r19-responsive.wikblb.xz', 1252,
  'b04077322097ea8bcdee4e3ca45f037f376617ff56b64170358f79e6aa775fe5', 30, 4259,
  'e735f12e030813c6e2b8496729fb3f88e9066a78f70409bb0c430f3ce7ed47dc');
const decodeOriginal = () => decode(original.payload, original.context);

test('the ordinary Babua member and both feature-absent and DPRY occurrence controls index and decode', async () => {
  const predecessor = await member('r08-image-occurrence.wikblb.xz', 1108,
    'a788ede6b4cc2745defe1c3250b5158a24ede116c07b7429c65ef96b22df3859', 30, 3970,
    'b6add840169fc5bc93563f36ace2fea1777b74983d8d3011377978d0ad69d6d0');
  assert.deepEqual([original.payload.subarray(0, 8).toString('hex'),
    predecessor.payload.subarray(0, 6).toString('hex')], ['4450526120210001', '4450525a2021']);
  const previous = decode(predecessor.payload, predecessor.context);
  const term = previous.sections[1].blocks[3].container.blocks[0].container.blocks[0].container.blocks[0].spans[0];
  assert.equal(term.image.occurrence_layout.y.value, -2);
  assert.equal(previous.sections[1].blocks[3].container.style.screen_max_width, undefined);
  assert.equal(decodeOriginal().presentation_version, 'DPRa');

  const occurrence = await readFile(new URL('synthetic-dpry-occurrence.bin', directory));
  assert.equal(sha256(occurrence), '9700880c55b1f2b34c5a7fad69f218595a2392b31abfde922c91435ee452a067');
  assert.equal(occurrence.subarray(0, 5).toString('hex'), '4450525920');
  const {rows} = await indexRaw(dictionaryBlob(7, [['Synthetic occurrence', occurrence]]));
  assert.deepEqual(rows.map(row => row.title), ['Synthetic occurrence']);
  assert.equal(decode(occurrence, {}).sections[0].blocks[0].spans[0].image.occurrence_layout.y.value, -2);
});

test('the genuine Babua payload retains the responsive owner, icon, ordered list and semantic audio credit', () => {
  const blocks = decodeOriginal().sections[1].blocks;
  const shell = blocks[3].container;
  assert.equal(shell.style.layout, 'flex_row');
  assert.deepEqual(shell.style.screen_max_width, {max_width_px: 720, layout: 'flow'});
  assert.deepEqual(shell.blocks.map(block => block.kind), ['container']);
  const term = shell.blocks[0].container.blocks[0].container.blocks[0].spans[0];
  assert.deepEqual([term.kind, term.target, term.image.width_px, term.image.height_px], ['text', '', 12, 12]);
  assert.deepEqual(term.image.occurrence_layout.y, {unit: 'px', value: -2});
  assert.deepEqual([blocks[4].container.style.layout, blocks[4].container.style.ordered_marker_weight], ['ordered_list', 'bold']);
  const audio = blocks[2].description_body.box;
  assert.equal(audio.style.line_height.multiplier, 1.625);
  const [play, credit] = audio.blocks[0].spans;
  assert.deepEqual([play.text, play.audio_control.presentation, credit.text, credit.superscript],
    ['Suara', 'phonos_button', 'ⓘ', true]);
  assert.equal(credit.inline_style.line_height.font_relative.factor, 1);
});

test('index and decode both refuse bad feature headers, and decode enforces the responsive band census', async () => {
  for (const mask of [0x2120, 0x01202120, 0x01402120, 0x01802120, 0x01002121]) {
    const changed = Buffer.from(original.raw);
    changed.writeUInt32LE(mask, original.offset + 4);
    await assert.rejects(indexRaw(changed), /Unsupported responsive presentation features/);
    assert.throws(() => decode(changed.subarray(original.offset), original.context), /Unsupported responsive presentation features/);
  }
  // Inline destinations now have a supported header. This header-only mutation
  // omits the per-block destination lists required by its advertised body grammar.
  const unusedDestination = Buffer.from(original.raw);
  unusedDestination.writeUInt32LE(0x11002120, original.offset + 4);
  await assert.doesNotReject(indexRaw(unusedDestination));
  assert.throws(() => decode(unusedDestination.subarray(original.offset), original.context));
  for (const flags of [0, 0x40]) {
    const header = Buffer.from([0x44, 0x50, 0x52, 0x59, flags]);
    await assert.rejects(indexRaw(dictionaryBlob(7, [['Header', header]])), /Unsupported owner geometry features/);
    assert.throws(() => decode(header, {}), /Unsupported owner geometry features/);
  }
  for (const [magic, size] of [['DPRY', 5], ['DPRZ', 6], ['DPRa', 8]]) {
    for (let length = 4; length < size; length++) {
      const header = Buffer.alloc(length);
      header.write(magic);
      const adjacent = dictionaryBlob(7, [['A', header], ['Z', Buffer.from('DPR2')]]);
      await assert.rejects(indexRaw(adjacent), /Truncated presentation header/);
      assert.throws(() => decode(header, {}), /Truncated presentation header/);
    }
  }
  // The genuine band consists of max width 720, no legacy fields and flow extension bit 0.
  const band = Buffer.from([0xd0, 0x02, 0, 0, 0, 1]);
  const at = original.payload.indexOf(band);
  assert.ok(at >= 8);
  assert.equal(original.payload.indexOf(band, at + 1), -1);
  const invalid = Buffer.from(original.payload);
  invalid[at + 5] = 2;
  assert.throws(() => decode(invalid, original.context));
  // A well-formed box-sizing-only band leaves the advertised flow capability unused.
  const withoutFlow = Buffer.concat([original.payload.subarray(0, at + 4), Buffer.from([4, 0, 0]),
    original.payload.subarray(at + band.length)]);
  assert.throws(() => decode(withoutFlow, original.context), /Missing responsive flow band/);
  assert.throws(() => decode(original.payload.subarray(0, -1), original.context));
  assert.throws(() => decode(Buffer.concat([original.payload, Buffer.alloc(1)]), original.context), /Trailing presentation data/);
});

test('responsive container and Phonos description validators refuse conflicting owners', () => {
  const blocks = decodeOriginal().sections[1].blocks;
  const owner = blocks[3];
  for (const change of [
    block => {block.container.style.layout = 'flow';},
    block => {block.container.blocks[0].container.style.flex_item = 'none';},
    block => {const child = block.container.blocks[0]; child.description_body = {box: child.container};},
    block => {block.container.style.screen_max_width.following_rules = [{max_width_px: 720, clear: 'none'}];},
  ]) {
    const invalid = structuredClone(owner);
    change(invalid);
    assert.throws(() => validateContainerBlock(invalid, modelOptions), /Invalid compiled container/);
  }
  const description = structuredClone(blocks[2]);
  description.description_body.box.blocks[0].spans[1].superscript = false;
  assert.throws(() => validateDescriptionBody(description), /Invalid compiled container/);
});
