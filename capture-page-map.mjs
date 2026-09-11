#!/usr/bin/env node
// capture-page-map — record the interactive structure of a page an agent must
// drive again later.
//
// Driving a bank, a cloud console or an ad platform costs most of its time in
// rediscovery: which control opens the dialog, which one silently does
// something else, what the default date range is. That knowledge is worth
// more than the run itself, and it evaporates when the session ends.
//
// This captures SHAPE ONLY. Labels, roles, and a stable selector for each
// interactive element. It deliberately does not record input values, text
// content of non-interactive nodes, or anything a page might be displaying,
// because those are the user's data and this output is meant to be committable.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const OUT = process.env.PAGE_MAP_OUT ?? '/tmp/page-map.json';
const BROWSER = process.env.AGENT_BROWSER ?? 'agent-browser';

// Values are never captured. A bank page holds balances in exactly the fields
// this would otherwise read.
const EXTRACT = `
(function () {
  function label(e) {
    var lab = '';
    if (e.id) {
      var l = document.querySelector('label[for=' + JSON.stringify(e.id) + ']');
      if (l) lab = l.innerText || '';
    }
    if (!lab && e.closest('label')) lab = e.closest('label').innerText || '';
    var raw = e.getAttribute('aria-label') || e.getAttribute('name') ||
              e.getAttribute('placeholder') || lab || e.id ||
              (e.tagName === 'BUTTON' || e.tagName === 'A' ? e.innerText : '');
    // String() because a stray undefined here serialises as the literal
    // "undefined", which reads like a real label and is worse than empty.
    raw = (raw === undefined || raw === null) ? '' : String(raw);
    // Some frameworks render name={undefined} as the literal attribute
    // name="undefined". Observed on a live banking SPA. Treat it as absent,
    // or the map claims a control is called "undefined".
    if (raw === 'undefined' || raw === 'null') raw = e.id || '';
    return raw.replace(/\\s+/g, ' ').trim().slice(0, 60);
  }
  function selector(e) {
    if (e.id) return '#' + CSS.escape(e.id);
    const al = e.getAttribute('aria-label');
    if (al) return e.tagName.toLowerCase() + '[aria-label=' + JSON.stringify(al.slice(0, 40)) + ']';
    const nm = e.getAttribute('name');
    if (nm) return e.tagName.toLowerCase() + '[name=' + JSON.stringify(nm) + ']';
    return null;
  }
  const sel = 'a,button,input,select,textarea,[role=button],[role=tab],[role=combobox]';
  const out = [];
  document.querySelectorAll(sel).forEach(function (e) {
    // offsetParent is also null for position:fixed elements (modals, sticky
    // toolbars) even when visible, so don't treat those as hidden.
    if (e.offsetParent === null && getComputedStyle(e).position !== 'fixed') return;
    const r = e.getBoundingClientRect();
    out.push({
      tag: e.tagName.toLowerCase(),
      type: e.getAttribute('type') || e.getAttribute('role') || null,
      label: label(e),
      selector: selector(e),
      disabled: !!e.disabled,
      // below_fold matters: a control the agent cannot see is the single most
      // common reason an automated click lands on the wrong element.
      below_fold: r.top > (window.innerHeight || 0) || r.bottom < 0,
      // Option COUNT only. Option TEXT is not captured and must not be:
      // on a bank page the options are account names, balances, card
      // numbers and saved payees. Knowing a select has 13 options is what
      // makes the next run fast; knowing what they say is the user's data.
      option_count: e.tagName === 'SELECT' ? e.options.length : undefined,
    });
  });
  return JSON.stringify({ url: location.href, title: document.title, count: out.length, elements: out });
})()
`;

function browser(...args) {
  return execFileSync(BROWSER, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}

function main() {
  let raw;
  try {
    raw = browser('eval', EXTRACT);
  } catch (err) {
    console.error('capture-page-map: FAILED agent-browser eval: ' + (err.message || err));
    process.exit(1);
  }
  // agent-browser returns the eval result as a JSON-encoded STRING, so the
  // payload needs unwrapping twice. Slicing at the first '{' looks right and
  // removes the opening quote, which fails confusingly.
  let map;
  try {
    const inner = JSON.parse(raw.trim());
    map = typeof inner === 'string' ? JSON.parse(inner) : inner;
  } catch (e) {
    console.error('capture-page-map: FAILED unparseable output: ' + e.message);
    process.exit(1);
  }
  if (!map.elements || map.elements.length === 0) {
    console.error('capture-page-map: FAILED zero interactive elements; a page ' +
                  'that appears empty is usually a redirect or a login wall, ' +
                  'not a page with no controls');
    process.exit(1);
  }
  map.captured_at = new Date().toISOString();
  fs.writeFileSync(OUT, JSON.stringify(map, null, 2));
  const below = map.elements.filter((e) => e.below_fold).length;
  console.log(`capture-page-map: ${map.count} controls (${below} below fold) -> ${OUT}`);
}

main();
