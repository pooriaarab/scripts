#!/usr/bin/env node
/**
 * Submit a hosted MCP server to the Claude Connectors Directory by driving the
 * 10-step wizard at claude.ai/directory/manage/new/connector in a logged-in
 * Chrome (browser-personal, CDP 9334).
 *
 *   node submit.mjs config.json [--dry-run]     submit for review
 *   node submit.mjs config.json --publish        approved -> live
 *   node submit.mjs config.json --status         read listing state
 *
 * Config shape (one file per site):
 * {
 *   "name": "private-repo-f838.fyi",          // listing name (prefilled from step 1 title, still set)
 *   "slug": "private-repo-f838-fyi",          // PERMANENT after submission
 *   "mcp_url": "https://private-repo-f838.fyi/mcp",
 *   "one_liner": "<=200 chars",
 *   "description": "<=2000 chars",
 *   "categories": ["Legal", "Data & Analytics"],   // exact option labels, max 5
 *   "docs_url": "https://private-repo-f838.fyi/developers",
 *   "support": "support@private-repo-f838.fyi",      // url or email
 *   "privacy_url": "https://private-repo-f838.fyi/privacy",
 *   "use_cases": [ { "use_case": "...", "prompt": "..." }, ... ],  // 1-3 pairs
 *   "prerequisites": "None. ...",           // what a user needs before connecting
 *   "company_website": "https://example.xyz",
 *   "contact_role": "Founder"
 * }
 *
 * Fixed answers for the read-only public directories (edit CONFIG_DEFAULTS if a
 * server differs): auth=None, data handling=own API/no health/no sponsored,
 * read-write=Read only.
 *
 * Mechanism notes (all learned the hard way — see README):
 * - React inputs need the native setter + input event; el.value=x silently no-ops.
 * - Category picker: focus+click the INPUT[role=combobox], then click the option
 *   element whose textContent matches the label exactly.
 * - Radio groups are spans; click the leaf span's closest group wrapper.
 * - Compliance/self-tested are checkboxes; click any not already checked.
 * - "Draft saved in this tab" survives reloads — the script is re-runnable: it
 *   reads the current step and resumes (a submitted server shows "submitted").
 * - Publish confirm is a position:fixed alertdialog — offsetParent is null by
 *   design, so detect it by role+text, not visibility. Its Publish button needs
 *   the full pointerdown/mousedown/pointerup/mouseup/click dispatch; a bare
 *   .click() does not fire the handler.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const CDP = process.env.AGENT_BROWSER_CDP || "9334";
const DRY = process.argv.includes("--dry-run");
const PUBLISH = process.argv.includes("--publish");
const STATUS = process.argv.includes("--status");
const configPath = process.argv.find((a, i) => i > 1 && !a.startsWith("--"));
if (!configPath) {
  console.error("usage: node submit.mjs config.json [--dry-run|--publish|--status]");
  process.exit(1);
}
const cfg = JSON.parse(readFileSync(configPath, "utf8"));
const REQUIRED = ["name", "slug", "mcp_url", "one_liner", "description", "categories",
  "docs_url", "support", "privacy_url", "use_cases", "prerequisites",
  "company_website", "contact_role"];
for (const k of REQUIRED) {
  const v = cfg[k];
  if (v === undefined || v === "" || (Array.isArray(v) && v.length === 0)) {
    console.error(`config missing "${k}"`);
    process.exit(1);
  }
}
if (!/^[a-z0-9-]+$/.test(cfg.slug)) { console.error("slug: lowercase letters, digits, hyphens only"); process.exit(1); }
if (cfg.use_cases.length > 3) { console.error("use_cases: max 3"); process.exit(1); }

// One agent-browser eval through the personal-profile zsh functions. The
// functions only exist in an interactive zsh, so every call is `zsh -ic`.
// Single-quote the expression: zsh re-parses the command line, and JSON
// double-quotes would be re-interpreted as shell quoting.
const shq = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
const ab = (expr) => {
  const cmd = `agent-browser --cdp ${CDP} eval ${shq(expr)}`;
  if (DRY) { console.log("dry:", cmd.slice(0, 120)); return '""'; }
  return execFileSync("zsh", ["-ic", cmd], { encoding: "utf8", timeout: 30000 }).trim();
};
const abRun = (sub) => {
  const cmd = `agent-browser --cdp ${CDP} ${sub}`;
  if (DRY) { console.log("dry:", cmd); return; }
  return execFileSync("zsh", ["-ic", cmd], { encoding: "utf8", timeout: 30000 }).trim();
};
const sleep = (ms) => { if (!DRY) execFileSync("sleep", [String(ms / 1000)]); };

const j = (v) => JSON.stringify(v);
// Indexed lookup used by steps 3-5 (index math verified against the live DOM).
const INS = `(i)=>[...document.querySelectorAll("input:not([type=hidden]),textarea")][i]`;

// Inject a value into input/textarea i by DOM index — React-safe.
const SET = `(el,v)=>{const p=el.tagName==="TEXTAREA"?HTMLTextAreaElement:HTMLInputElement;Object.getOwnPropertyDescriptor(p.prototype,"value").set.call(el,v);el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}));return el.value.length}`;
const clickBtn = (label) => `(()=>{const b=[...document.querySelectorAll("button")].find(b=>b.innerText.trim()===${j(label)});if(!b)return "MISSING "+${j(label)};b.click();return "ok"})()`;
const stepNow = `(()=>{const m=document.body.innerText.match(/Step (\\d+) of 10|submitted for review/);return m?m[0]:"unknown"})()`;
const waitStep = (want, tries = 10) => {
  for (let n = 0; n < tries; n++) {
    const s = JSON.parse(ab(stepNow));
    if (s.includes(want)) return s;
    sleep(1200);
  }
  throw new Error(`wizard never reached "${want}" — still at ${ab(stepNow)}`);
};
const next = (from, to) => {
  console.log(`step ${from} -> ${to}`);
  const r = JSON.parse(ab(clickBtn("Next")));
  if (r !== "ok") throw new Error(`Next button missing at step ${from}`);
  return waitStep(`Step ${to}`);
};

console.log("site:", cfg.name, "| cdp", CDP, DRY ? "(dry)" : "");

const DETAIL = `https://claude.ai/directory/manage/${cfg.slug}`;
const LIST = "https://claude.ai/directory/manage";
// Listing state on the detail page: the checklist shows Submitted/Approved/
// Published each as "(done)" or the pending variant; "In review" and
// "Ready to publish" appear while awaiting a step.
const readState = `(()=>{const t=document.body.innerText;const i=t.indexOf("Submitted");const seg=i<0?t.slice(0,300):t.slice(i,i+300);const m=seg.match(/In review|Ready to publish|Published|Approved|Live\\s*\\n?\\s*\\(?(not yet)?/);return m?m[0].replace(/\\n/g," "):seg.slice(0,80)})()`;

if (STATUS) {
  abRun(`open ${LIST}`);
  sleep(5000);
  const row = JSON.parse(ab(`(()=>{const t=document.body.innerText;const i=t.indexOf(${j(cfg.name.split(" ")[0])});return i<0?"not on submissions page":t.slice(Math.max(0,i-40),i+120)})()`));
  console.log(`${cfg.name}: ${row.replace(/\n+/g, " | ")}`);
  process.exit(0);
}

if (PUBLISH) {
  abRun(`open ${DETAIL}`);
  sleep(6000);
  let st = JSON.parse(ab(readState));
  if (st.includes("Published")) { console.log(`DONE: ${cfg.name} already published`); process.exit(0); }
  if (!st.includes("Ready to publish") && !st.includes("Approved")) {
    console.error(`FAILED: not publishable yet (state: ${st})`); process.exit(1);
  }
  const r1 = JSON.parse(ab(clickBtn("Publish")));
  if (r1 !== "ok") throw new Error("Publish button missing on detail page");
  sleep(3000);
  // The confirm dialog is position:fixed (offsetParent null). Detect by
  // role+text and dispatch the full mouse sequence — .click() alone no-ops.
  const r2 = JSON.parse(ab(`(()=>{const d=[...document.querySelectorAll("[role=alertdialog],[role=dialog]")].find(e=>e.innerText.includes("Publish this server"));if(!d)return "nodlg";const b=[...d.querySelectorAll("button")].find(x=>x.innerText.trim()==="Publish");if(!b)return "no confirm btn";const r=b.getBoundingClientRect();const o={bubbles:true,cancelable:true,view:window,button:0,clientX:r.x+r.width/2,clientY:r.y+r.height/2};b.dispatchEvent(new PointerEvent("pointerdown",o));b.dispatchEvent(new MouseEvent("mousedown",o));b.dispatchEvent(new PointerEvent("pointerup",o));b.dispatchEvent(new MouseEvent("mouseup",o));b.dispatchEvent(new MouseEvent("click",o));return "dispatched"})()`));
  if (r2 !== "dispatched") throw new Error(`confirm dialog: ${r2}`);
  sleep(5000);
  st = JSON.parse(ab(readState));
  if (!st.includes("Published")) {
    console.error(`FAILED: publish not confirmed (state: ${st})`); process.exit(1);
  }
  console.log(`DONE: ${cfg.name} published`);
  process.exit(0);
}

// Step 1 — Connection: set the URL, connect, wait for tools to be read.
const at = JSON.parse(ab(stepNow));
console.log("wizard at:", at);
if (at=== `Step 1 of 10`) {
  console.log("step 1: enter URL + connect");
  // Fast path: a connector is already selected and connected (draft resume).
  const already = JSON.parse(ab(`(()=>{const m=document.body.innerText.match(/(\\d+) Tools/);return m&&!m[0].startsWith("0")})()`));
  let r;
  if (already) {
    console.log("already connected:", JSON.parse(ab(`document.body.innerText.match(/(\\d+) Tools/)[0]`)));
  } else {
  // Step 1 opens on a connector list; the URL field lives behind a dialog that
  // may already be open (draft state). Only click Add when it is absent.
  const dlgOpen = JSON.parse(ab(`(()=>{const ins=[...document.querySelectorAll("input:not([type=hidden]),textarea")].filter(e=>e.offsetParent);return !!ins.find(e=>e.placeholder&&e.placeholder.includes("URL"))})()`));
  if (!dlgOpen) {
    r = JSON.parse(ab(clickBtn("Add custom connector")));
    if (r !== "ok") r = JSON.parse(ab(clickBtn("Add connector")));
    console.log("add dialog:", r);
    sleep(1500);
  } else {
    console.log("dialog already open");
  }
  // Dialog inputs are placeholder-labelled: "Name" and "MCP server URL".
  const filled = JSON.parse(ab(`(()=>{const ins=[...document.querySelectorAll("input:not([type=hidden]),textarea")].filter(e=>e.offsetParent);
    const nm=ins.find(e=>e.placeholder==="Name");const url=ins.find(e=>e.placeholder&&e.placeholder.includes("URL"));
    if(!url)return "no-url-input";const set=${SET};
    if(nm)set(nm,${j(cfg.name)});return set(url,${j(cfg.mcp_url)})})()`));
  console.log("dialog fill:", filled);
  sleep(800);
  // Dialog step 1 (name+URL) -> Continue -> dialog step 2 (auth; "No sign-in"
  // is auto-Detected for open servers) -> Add finishes and connects.
  r = JSON.parse(ab(clickBtn("Continue")));
  console.log("dialog continue:", r);
  sleep(2000);
  r = JSON.parse(ab(clickBtn("Add")));
  console.log("dialog add:", r);
  // Wait for "N Tools" (connected) — up to 30s.
  for (let n = 0; n < 15; n++) {
    const s = JSON.parse(ab(`(()=>{const m=document.body.innerText.match(/(\\d+) Tools|not connected|status 400/);return m?m[0]:"waiting"})()`));
    if (s.endsWith("Tools") && !s.startsWith("0")) { console.log("connected:", s); break; }
    if (/not connected|status 400/.test(s) && n > 4) {
      console.log("still unconnected, retrying connect click");
      JSON.parse(ab(clickBtn("Connect and authorize")));
    }
    if (n === 14) throw new Error(`connection never read tools (last: ${s})`);
    sleep(2000);
  }
  } // end else (not already connected)
  next(1, 2);
}

// Step 2 — Tools review: nothing to fill.
if (JSON.parse(ab(stepNow))=== `Step 2 of 10`) next(2, 3);

// Step 3 — Listing. DOM order: name(3) slug(4) one-liner(5) desc(6) cats(7) author(9,10) docs(11) entdocs(12) support(13) privacy(14).
if (JSON.parse(ab(stepNow))=== `Step 3 of 10`) {
  console.log("step 3: listing fields");
  const fills = [[3, cfg.name], [4, cfg.slug], [5, cfg.one_liner], [6, cfg.description],
    [11, cfg.docs_url], [13, cfg.support], [14, cfg.privacy_url]];
  for (const [i, v] of fills) ab(`(${SET})((${INS})(${i}),${j(v)})`);
  // Categories via the input combobox.
  ab(`(()=>{const inp=[...document.querySelectorAll("input[role=combobox]")][0];inp.focus();inp.click();return "open"})()`);
  sleep(800);
  for (const cat of cfg.categories) {
    const r = JSON.parse(ab(`(()=>{const lbs=[...document.querySelectorAll("[role=listbox]")].filter(l=>l.offsetParent);const lb=lbs[lbs.length-1];const o=[...lb.children].find(x=>x.textContent.trim()===${j(cat)});if(!o)return ${j("MISS "+cat)};o.click();return "ok"})()`));
    console.log("  category:", r);
    sleep(400);
  }
  // Close the listbox, then Next.
  ab(`document.body.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}))`);
  sleep(400);
  next(3, 4);
}

// Step 4 — Use cases: pairs at inputs 3..8, prerequisites textarea (9), read_only radio (10).
if (JSON.parse(ab(stepNow))=== `Step 4 of 10`) {
  console.log("step 4: use cases");
  for (const [k, uc] of cfg.use_cases.entries()) {
    ab(`(${SET})((${INS})(${3 + k * 2}),${j(uc.use_case)})`);
    ab(`(${SET})((${INS})(${4 + k * 2}),${j(uc.prompt)})`);
  }
  ab(`(${SET})((${INS})(9),${j(cfg.prerequisites)})`);
  ab(`(()=>{const ro=[...document.querySelectorAll("input[type=radio]")].find(e=>e.value==="read_only");ro.click();return ro.checked})()`);
  next(4, 5);
}

// Step 5 — Company: name/contact prefilled from the account; fill website(4) + role(7).
if (JSON.parse(ab(stepNow))=== `Step 5 of 10`) {
  console.log("step 5: company");
  ab(`(${SET})((${INS})(4),${j(cfg.company_website)})`);
  ab(`(${SET})((${INS})(7),${j(cfg.contact_role)})`);
  next(5, 6);
}

// Step 6 — Authentication: click the "None" span's group wrapper.
if (JSON.parse(ab(stepNow))=== `Step 6 of 10`) {
  console.log("step 6: auth = none");
  ab(`(()=>{const inp=[...document.querySelectorAll("input[type=radio],input")].find(e=>e.value==="no_auth"||e.value==="none");
    if(inp){inp.click();return "radio:"+inp.value}
    const s=[...document.querySelectorAll("span,div")].find(e=>e.textContent.trim()==="None");
    if(!s)return "MISS None";const g=s.closest("span[class*=group],label")||s;g.click();return "span"})()`);
  sleep(500);
  next(6, 7);
}

// Step 7 — Data handling: "We own the API", first "No" (health), second "No" (sponsored).
if (JSON.parse(ab(stepNow))=== `Step 7 of 10`) {
  console.log("step 7: data handling");
  ab(`(()=>{const pick=t=>{const s=[...document.querySelectorAll("span")].find(e=>e.childElementCount===0&&e.textContent.trim()===t);const g=s.closest("span[class*=group],label");(g||s).click()};pick("We own the API");const nos=[...document.querySelectorAll("span")].filter(e=>e.childElementCount===0&&e.textContent.trim()==="No");nos.forEach(n=>{const g=n.closest("span[class*=group],label");(g||n).click()});return nos.length})()`);
  sleep(500);
  next(7, 8);
}

// Step 8 — Test & launch: instructions textarea + self-tested checkbox.
if (JSON.parse(ab(stepNow))=== `Step 8 of 10`) {
  console.log("step 8: test & launch");
  const instructions = cfg.test_instructions ||
    `No account or credentials needed — the server is public. Add ${cfg.mcp_url} as a custom connector with no sign-in, then call any tool (e.g. search_listings with q="Austin" returns results with sources).`;
  ab(`(()=>{const ta=[...document.querySelectorAll("textarea")].filter(e=>e.offsetParent)[0];const setter=Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,"value").set;setter.call(ta,${j(instructions)});ta.dispatchEvent(new Event("input",{bubbles:true}));const cbs=[...document.querySelectorAll("input[type=checkbox],[role=checkbox]")].filter(e=>e.offsetParent);cbs.forEach(c=>{if(!c.checked&&c.getAttribute("aria-checked")!=="true")c.click()});return "ok"})()`);
  sleep(500);
  next(8, 9);
}

// Step 9 — Compliance: check every visible checkbox.
if (JSON.parse(ab(stepNow))=== `Step 9 of 10`) {
  console.log("step 9: compliance");
  ab(`(()=>{const cbs=[...document.querySelectorAll("input[type=checkbox],[role=checkbox]")].filter(e=>e.offsetParent);cbs.forEach(c=>{if(!c.checked&&c.getAttribute("aria-checked")!=="true")c.click()});return cbs.filter(c=>!(c.checked||c.getAttribute("aria-checked")==="true")).length})()`);
  sleep(500);
  next(9, 10);
}

// Step 10 — Review and submit.
if (JSON.parse(ab(stepNow))=== `Step 10 of 10`) {
  console.log("step 10: submitting");
  const r = JSON.parse(ab(clickBtn("Submit for review")));
  if (r !== "ok") throw new Error("Submit for review button missing");
  waitStep("submitted for review", 15);
}

const final = JSON.parse(ab(stepNow));
if (!final.includes("submitted for review")) {
  console.error(`FAILED: wizard is at "${final}" — submission not confirmed`);
  process.exit(1);
}
console.log(`DONE: ${cfg.name} submitted for review`);
