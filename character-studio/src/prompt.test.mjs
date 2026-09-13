import assert from 'node:assert/strict';
import test from 'node:test';

import { buildPrompt, buildSheetPrompt } from './prompt.mjs';

const character = {
  render: { look: 'natural light', never: 'plastic skin' },
  wardrobe: { default: 'grey suit' },
  name: 'Jamie Doe',
  anchors: [
    { id: 'height', weight: 3, requires: 'body', check: 'true height' },
    { id: 'eyes', weight: 2, check: 'eyes match' },
  ],
};

const shot = {
  framing: 'medium shot',
  scene: 'office',
  wardrobe: 'blue shirt',
  expression: 'neutral',
  light: 'window light',
};

test('buildPrompt writes the shot fields, and shot.extra only when the shot has it', () => {
  const out = buildPrompt({ character, shot });
  assert.match(out, /Framing: medium shot/);
  assert.match(out, /Scene: office/);
  assert.match(out, /Wardrobe: blue shirt/);
  assert.match(out, /Expression: neutral/);
  assert.match(out, /Light: window light/);
  assert.doesNotMatch(out, /Also:/);
  assert.match(buildPrompt({ character, shot: { ...shot, extra: 'holding a coffee cup' } }), /Also: holding a coffee cup/);
});

test('buildPrompt marks only anchors at or above the critical weight, default or pack-lowered', () => {
  const out = buildPrompt({ character, shot: { ...shot, scope: 'full' } });
  assert.match(out, /- true height {2}\(critical\)/);
  assert.doesNotMatch(out, /- eyes match {2}\(critical\)/);

  const lowered = { ...character, verification: { critical_weight: 2 } };
  assert.match(buildPrompt({ character: lowered, shot: { ...shot, scope: 'full' } }), /- eyes match {2}\(critical\)/);
});

test('buildPrompt drops body-only anchors for a scoped shot', () => {
  // A waist-up shot cannot show height, and scoring it there produces a failure
  // no prompt can fix, so the checklist must not ask the model for it.
  const out = buildPrompt({ character, shot: { ...shot, scope: 'head' } });
  assert.doesNotMatch(out, /true height/);
  assert.match(out, /eyes match/);
});

test('buildPrompt appends corrections only when given', () => {
  assert.doesNotMatch(buildPrompt({ character, shot }), /FIX THESE FAULTS/);
  const withCorrections = buildPrompt({ character, shot, corrections: ['beard is too full'] });
  assert.match(withCorrections, /FIX THESE FAULTS FROM THE PREVIOUS ATTEMPT/);
  assert.match(withCorrections, /- beard is too full/);
});

test('buildSheetPrompt titles the board, embeds it, and does not scope anchors like buildPrompt does', () => {
  const out = buildSheetPrompt({ character, board: 'PANEL LAYOUT HERE' });
  assert.match(out, /Title the board exactly: JAMIE DOE — CHARACTER REFERENCE/);
  assert.match(out, /PANEL LAYOUT HERE/);
  // A production sheet always covers the full character, unlike a single shot.
  assert.match(out, /true height/);
});

test('buildSheetPrompt prefers sheetWardrobe over the default wardrobe', () => {
  assert.match(buildSheetPrompt({ character, board: 'board' }), /Dress him the same way in every panel: grey suit/);
  const withSheetWardrobe = buildSheetPrompt({ character: { ...character, sheetWardrobe: 'lab coat' }, board: 'board' });
  assert.match(withSheetWardrobe, /Dress him the same way in every panel: lab coat/);
});

test('buildSheetPrompt appends corrections only when given', () => {
  assert.doesNotMatch(buildSheetPrompt({ character, board: 'board' }), /FIX THESE FAULTS/);
  const withCorrections = buildSheetPrompt({ character, board: 'board', corrections: ['hairstyle drifted in panel 3'] });
  assert.match(withCorrections, /FIX THESE FAULTS FROM THE PREVIOUS ATTEMPT/);
  assert.match(withCorrections, /- hairstyle drifted in panel 3/);
});
