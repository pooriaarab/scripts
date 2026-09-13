import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  allShots,
  anchorsForScope,
  applyVariant,
  criticalAnchors,
  findShot,
  loadPack,
  refSource,
} from './pack.mjs';

function writePack(root, { character, shots } = {}) {
  fs.writeFileSync(path.join(root, 'character.json'), JSON.stringify(character));
  if (shots !== undefined) fs.writeFileSync(path.join(root, 'shots.json'), JSON.stringify(shots));
}

const baseCharacter = {
  references: [{ file: 'front.jpg', url: 'https://cdn.example/front.jpg' }],
  anchors: [
    { id: 'jaw', weight: 3, requires: 'body', check: 'jaw matches' },
    { id: 'eyes', weight: 2, check: 'eyes match' },
  ],
};

test('loadPack defaults shots.json when absent, and refUrl resolves declared references only', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pack-load-'));
  try {
    writePack(root, { character: baseCharacter });
    const pack = await loadPack(root);
    assert.deepEqual(pack.shots, { defaults: {}, shots: [] });
    assert.equal(pack.refUrl('front.jpg'), 'https://cdn.example/front.jpg');
    assert.throws(() => pack.refUrl('missing.jpg'), /Unknown reference "missing\.jpg"/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('loadPack throws when a reference has no CDN url', async () => {
  // The error names the fix (`character-studio refs <dir>`) rather than just
  // failing, so an operator is not left to guess why generation stopped.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pack-nourl-'));
  try {
    writePack(root, {
      character: { references: [{ file: 'front.jpg' }], anchors: [] },
      shots: { defaults: {}, shots: [] },
    });
    await assert.rejects(() => loadPack(root), /front\.jpg has no CDN url/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('refSource prefers the local file over the CDN url', async () => {
  // Reference photographs are gitignored, so a fresh clone has no refs/
  // directory and must fall back to the network without failing.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pack-refsource-'));
  try {
    writePack(root, { character: baseCharacter, shots: { defaults: {}, shots: [] } });
    const pack = await loadPack(root);
    assert.equal(refSource(pack, 'front.jpg'), 'https://cdn.example/front.jpg');
    fs.mkdirSync(path.join(root, 'refs'));
    fs.writeFileSync(path.join(root, 'refs', 'front.jpg'), 'binary');
    assert.equal(refSource(pack, 'front.jpg'), path.join(root, 'refs', 'front.jpg'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('applyVariant is a no-op without a variantId, and throws for an undeclared one', () => {
  const character = { anchors: [], variants: { long: {} } };
  assert.equal(applyVariant(character, undefined), character);
  assert.throws(() => applyVariant(character, 'short'), /Unknown variant "short"\. Declared: long/);
});

test('applyVariant overrides only the fields it names on the anchors it names', () => {
  const character = {
    anchors: [
      { id: 'beard', weight: 3, check: 'sparse cheeks, short beard' },
      { id: 'eyes', weight: 2, check: 'eyes match' },
    ],
    variants: { long: { anchors: { beard: { check: 'sparse cheeks, long beard' } } } },
  };
  const applied = applyVariant(character, 'long');
  assert.equal(applied.anchors.find((a) => a.id === 'beard').check, 'sparse cheeks, long beard');
  assert.equal(applied.anchors.find((a) => a.id === 'beard').weight, 3);
  assert.equal(applied.anchors.find((a) => a.id === 'eyes').check, 'eyes match');
});

test('findShot and allShots merge the pack defaults, and findShot throws for an unknown id', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pack-shots-'));
  try {
    writePack(root, {
      character: baseCharacter,
      shots: { defaults: { light: 'soft' }, shots: [{ id: 'a', framing: 'close' }, { id: 'b', light: 'hard' }] },
    });
    const pack = await loadPack(root);
    assert.deepEqual(findShot(pack, 'a'), { light: 'soft', id: 'a', framing: 'close' });
    assert.throws(() => findShot(pack, 'missing'), /Unknown shot "missing"/);
    assert.deepEqual(allShots(pack), [
      { id: 'a', light: 'soft', framing: 'close' },
      { id: 'b', light: 'hard' },
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('anchorsForScope keeps body anchors only at full scope, which is also the default', () => {
  assert.equal(anchorsForScope(baseCharacter, 'full').length, 2);
  assert.equal(anchorsForScope(baseCharacter).length, 2);
  assert.deepEqual(anchorsForScope(baseCharacter, 'head').map((a) => a.id), ['eyes']);
});

test('criticalAnchors uses the default weight of 3 unless the pack overrides it', () => {
  assert.deepEqual(criticalAnchors(baseCharacter).map((a) => a.id), ['jaw']);
  const lowered = { ...baseCharacter, verification: { critical_weight: 2 } };
  assert.deepEqual(criticalAnchors(lowered).map((a) => a.id), ['jaw', 'eyes']);
});
