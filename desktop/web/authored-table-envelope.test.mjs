import assert from 'node:assert/strict';
import test from 'node:test';
import {decode} from './blob.js';

function header(version, features, census) {
  const bytes = new Uint8Array(9);
  bytes.set(new TextEncoder().encode(version));
  new DataView(bytes.buffer).setUint32(4, features, true);
  bytes[8] = census;
  return bytes;
}

test('authored table envelope refuses private version, unknown features and invalid census', () => {
  const metadata = {title:'control', kind:'supplemental'};
  assert.throws(() => decode(header('DPRb', 0, 1), metadata), /uncompiled records/);
  for (const features of [1, 0x9000, 0x01001000, 0x80001000]) {
    assert.throws(() => decode(header('DPRc', features, 1), metadata), /unsupported authored table inherited features/i);
  }
  assert.throws(() => decode(header('DPRc', 0, 4), metadata), /unsupported authored table inherited features/i);
  assert.throws(() => decode(header('DPRc', 0x2004, 1), metadata), /unsupported authored table inherited features/i);
  for (const census of [0, 8, 0x80]) {
    assert.throws(() => decode(header('DPRc', 0, census), metadata), /invalid authored table feature word/i);
  }
  assert.throws(() => decode(header('DPRc', 0, 1).subarray(0, 8), metadata), /truncated presentation header/i);
});
