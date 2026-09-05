import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Exactly `Assisted-by: <agent>:<model>`. Agent has no slash or backtick;
// neither field has internal whitespace, commas, or backticks.
export const ASSISTED_BY_VALID_RE = /^Assisted-by:\s*([^\s:,/`]+):([^\s:,`]+)\s*$/i;

const ROUTING_PATH = fileURLToPath(new URL('./agent-routing.json', import.meta.url));

export function isValidAssistedByLine(line) {
  return ASSISTED_BY_VALID_RE.test(line);
}

export function assistedByLinesFromBody(body) {
  if (!body) return [];
  return body.split('\n').filter((line) => /^\s*assisted-by:/i.test(line));
}

export function parseAssistedByLabel(body) {
  for (const line of assistedByLinesFromBody(body)) {
    const match = ASSISTED_BY_VALID_RE.exec(line);
    if (match) return `${match[1]}:${match[2]}`;
  }
  const loose = (body || '').match(/^\s*assisted-by:\s*(\S+)/im);
  if (loose) {
    const val = loose[1].replace(/[.,;)\]]+$/, '');
    if (val) return val;
  }
  return 'unattributed';
}

export function loadAssistedByAliases(routingPath = ROUTING_PATH) {
  const raw = JSON.parse(fs.readFileSync(routingPath, 'utf8'));
  const canonicalToAliases = raw.assistedByAliases || {};
  const aliasToCanonical = new Map();
  for (const [canonical, aliases] of Object.entries(canonicalToAliases)) {
    for (const alias of aliases) {
      aliasToCanonical.set(alias, canonical);
    }
  }
  return { aliasToCanonical };
}

export function normalizeAssistedByLabel(label, aliasToCanonical) {
  if (!label || label === 'unattributed') {
    return { canonical: 'unattributed', mergedFrom: [] };
  }
  const canonical = aliasToCanonical.get(label) || label;
  const mergedFrom = canonical === label ? [] : [label];
  return { canonical, mergedFrom };
}

export function formatAgentLabel(canonical, mergedFrom) {
  if (!mergedFrom.length) return canonical;
  return `${canonical} (merged ${mergedFrom.join(', ')})`;
}
