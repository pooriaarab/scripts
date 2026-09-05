import assert from 'node:assert/strict';
import test from 'node:test';

import {
  formatAgentLabel,
  isValidAssistedByLine,
  loadAssistedByAliases,
  normalizeAssistedByLabel,
  parseAssistedByLabel,
} from './assisted-by.mjs';

test('valid Assisted-by lines match the documented shape', () => {
  assert.equal(isValidAssistedByLine('Assisted-by: cursor:composer-2.5'), true);
  assert.equal(isValidAssistedByLine('Assisted-by: claude-personal-1:swe-1.7'), true);
  assert.equal(isValidAssistedByLine('Assisted-by: pooriaarab/scripts:pr-standards-rollout'), false);
  assert.equal(isValidAssistedByLine('Assisted-by: `:`'), false);
});

test('parseAssistedByLabel reads the first valid trailer', () => {
  const body = [
    'Closes #1',
    '',
    'Assisted-by: cursor:composer',
    'Assisted-by: muse:meta-code',
  ].join('\n');
  assert.equal(parseAssistedByLabel(body), 'cursor:composer');
  assert.equal(parseAssistedByLabel(''), 'unattributed');
});

test('aliases from agent-routing.json fold to one canonical label', () => {
  const { aliasToCanonical } = loadAssistedByAliases();
  assert.deepEqual(
    normalizeAssistedByLabel('cursor:composer', aliasToCanonical),
    { canonical: 'cursor:composer-2.5', mergedFrom: ['cursor:composer'] },
  );
  assert.deepEqual(
    normalizeAssistedByLabel('claude-personal-1:swe-1-7', aliasToCanonical),
    { canonical: 'claude-personal-1:swe-1.7', mergedFrom: ['claude-personal-1:swe-1-7'] },
  );
  assert.deepEqual(
    normalizeAssistedByLabel('unattributed', aliasToCanonical),
    { canonical: 'unattributed', mergedFrom: [] },
  );
});

test('formatAgentLabel names merged aliases in the output', () => {
  assert.equal(
    formatAgentLabel('cursor:composer-2.5', ['cursor:composer']),
    'cursor:composer-2.5 (merged cursor:composer)',
  );
  assert.equal(formatAgentLabel('cursor:composer-2.5', []), 'cursor:composer-2.5');
});
