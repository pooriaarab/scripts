import { readdir, readFile, writeFile, copyFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

/**
 * Builds a self-contained contact sheet: every shot, every attempt, every anchor
 * score, next to the real reference photographs. The point is that a human can
 * disagree with the verifier — so the evidence has to be on the same page.
 */
export async function writeReport(pack, outDir, webDir, baseHref) {
  const dest = webDir ?? outDir;
  await mkdir(dest, { recursive: true });

  const files = (await readdir(outDir)).sort();
  const reports = [];
  for (const f of files) {
    if (!f.endsWith(".report.json")) continue;
    reports.push(JSON.parse(await readFile(path.join(outDir, f), "utf8")));
  }

  // Attempts from a shot that is still running have no report yet. Show them
  // anyway, so a long gallery run is watchable instead of a blank page.
  const done = new Set(reports.flatMap((r) => r.attempts.map((a) => a.file)));
  const pending = files.filter((f) => /\.attempt-\d+\.(jpg|jpeg|png|webp)$/i.test(f) && !done.has(f));

  const refsDir = path.join(pack.dir, "refs");
  const refDest = path.join(dest, "refs");
  await mkdir(refDest, { recursive: true });
  for (const r of pack.character.references) {
    const src = path.join(refsDir, r.file);
    if (existsSync(src)) await copyFile(src, path.join(refDest, r.file));
  }

  if (dest !== outDir) {
    for (const f of await readdir(outDir)) {
      if (/\.(jpg|jpeg|png|webp)$/i.test(f)) await copyFile(path.join(outDir, f), path.join(dest, f));
    }
  }

  const file = path.join(dest, "index.html");
  await writeFile(file, html(pack, reports, pending, webDir ? baseHref : undefined));
  return file;
}

const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

const pct = (n) => `${(n * 100).toFixed(1)}%`;

function bar(score) {
  const cls = score >= 5 ? "s5" : score >= 4 ? "s4" : score >= 3 ? "s3" : score > 0 ? "s1" : "s0";
  return `<span class="dots ${cls}">${"●".repeat(Math.max(score, 0))}${"○".repeat(Math.max(5 - score, 0))}</span>`;
}

function html(pack, reports, pending = [], baseHref, builtAt = new Date().toISOString()) {
  const c = pack.character;
  const sheets = reports.filter((r) => r.group === "sheet");
  const shots = reports.filter((r) => r.group !== "sheet");
  const passed = reports.filter((r) => r.passed).length;

  return `<!doctype html>
<meta charset="utf-8">
${baseHref ? `<base href="${esc(baseHref)}">` : ""}
<title>${esc(c.name)} — character studio</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--ink:#15130f;--mut:#6b655c;--line:#e2ddd3;--bg:#faf8f4;--card:#fff;--ok:#2e7d4f;--bad:#b03030;--warn:#b07d2e}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Inter,sans-serif}
.wrap{max-width:1240px;margin:0 auto;padding:40px 24px 96px}
h1{font-size:30px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:19px;margin:48px 0 14px;letter-spacing:-.01em;border-bottom:1px solid var(--line);padding-bottom:8px}
h3{font-size:15px;margin:0 0 2px}
.sub{color:var(--mut);margin:0 0 28px}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:12px;font-weight:600;letter-spacing:.02em}
.pass{background:#e5f3ea;color:var(--ok)} .fail{background:#f8e7e7;color:var(--bad)}
.grid{display:grid;gap:18px}
.refs{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}
.refs figure{margin:0}
.refs img{width:100%;aspect-ratio:3/4;object-fit:cover;border-radius:8px;border:1px solid var(--line);background:#fff}
.refs figcaption{font-size:12px;color:var(--mut);margin-top:6px}
.shots{grid-template-columns:repeat(auto-fill,minmax(330px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.card>img{width:100%;display:block;background:#efece6;cursor:zoom-in}
.card .body{padding:14px 15px 16px}
.row{display:flex;justify-content:space-between;align-items:baseline;gap:10px;margin-bottom:10px}
.meta{font-size:12px;color:var(--mut)}
table{width:100%;border-collapse:collapse;font-size:12.5px}
td{padding:3px 0;vertical-align:top}
td.w{width:14px;color:var(--mut)} td.d{width:62px;white-space:nowrap}
.dots{letter-spacing:1px}
.s5{color:var(--ok)} .s4{color:var(--ok);opacity:.75} .s3{color:var(--warn)} .s1{color:var(--bad)} .s0{color:#c9c4ba}
details{margin-top:12px;font-size:13px}
summary{cursor:pointer;color:var(--mut)}
.corr{color:var(--bad);font-size:12px;margin:2px 0 0 0;padding-left:10px;border-left:2px solid #f0d6d6}
.obs{color:var(--mut);font-size:12px;padding-left:10px}
.sheetimg{width:100%;border:1px solid var(--line);border-radius:12px;display:block;background:#fff;cursor:zoom-in}
.anchors li{margin-bottom:10px}
.anchors b{display:block}
.anchors .must{color:var(--ink)} .anchors .never{color:var(--bad)}
dialog{border:0;background:transparent;max-width:96vw;max-height:96vh;padding:0}
dialog::backdrop{background:rgba(20,18,15,.9)}
dialog img{max-width:96vw;max-height:96vh;display:block;border-radius:6px}
code{background:#f0ece4;padding:1px 5px;border-radius:4px;font-size:12.5px}
</style>
<div class="wrap">
<h1>${esc(c.name)} — character studio</h1>
<p class="sub">Pack v${esc(c.version)}, updated ${esc(c.updated)}. Verified by <code>${esc(c.verification.model)}</code> against ${c.anchors.length} identity anchors.
Pass needs a weighted score of ${pct(c.verification.pass_score)} and at least ${c.verification.critical_min}/5 on every critical anchor.
<strong>${passed}/${reports.length} passed.</strong></p>

<h2>Ground truth — the real photographs</h2>
<div class="grid refs">
${c.references
  .map(
    (r) => `<figure><img src="refs/${esc(r.file)}" alt="${esc(r.file)}" onclick="z(this.src)">
<figcaption><strong>${esc(r.role)}</strong><br>${esc(r.notes)}</figcaption></figure>`,
  )
  .join("\n")}
</div>

${sheets
  .sort((a, b) => b.score - a.score)
  .map(
    (sheet) => `<h2>Character sheet — ${esc(sheet.model)} <span class="pill ${sheet.passed ? "pass" : "fail"}">${sheet.passed ? "PASS" : "FAIL"} ${pct(sheet.score)}</span></h2>
<img class="sheetimg" src="${esc(sheet.final)}" alt="character sheet" onclick="z(this.src)">
${attemptsBlock(sheet)}`,
  )
  .join("\n")}

<h2>Gallery</h2>
<div class="grid shots">
${shots.map(card).join("\n")}
</div>

${
  pending.length
    ? `<h2>In flight <span class="pill fail">${pending.length} not scored yet</span></h2>
<p class="sub">These attempts are rendered but the run has not finished scoring them. They may still be rejected.</p>
<div class="grid refs">
${pending
  .map((f) => `<figure><img src="${esc(f)}" loading="lazy" onclick="z(this.src)"><figcaption>${esc(f)}</figcaption></figure>`)
  .join("\n")}
</div>`
    : ""
}

<h2>The identity lock</h2>
<ol class="anchors">
${c.anchors
  .map(
    (a) => `<li><b>${esc(a.label)} — weight ${a.weight}</b>
<span class="must">${esc(a.must)}</span><br>
<span class="never">Never: ${esc(a.never)}</span><br>
<span class="meta">Why: ${esc(a.why)}</span></li>`,
  )
  .join("\n")}
</ol>
</div>
<dialog id="lb" onclick="this.close()"><img id="lbi"></dialog>
<p class="meta" style="margin-top:40px">Built ${esc(builtAt)}. This page reloads itself while a run is in flight, and keeps your scroll position.</p>
<script>
function z(s){document.getElementById('lbi').src=s;document.getElementById('lb').showModal()}
// Auto-reload so a long run is watchable without clicking. Scroll position is
// restored, otherwise every reload throws the reader back to the top.
(function () {
  const KEY = "cs-scroll";
  const y = sessionStorage.getItem(KEY);
  if (y) { window.scrollTo(0, Number(y)); sessionStorage.removeItem(KEY); }
  const stamp = ${JSON.stringify(builtAt)};
  setInterval(async () => {
    if (document.getElementById("lb").open) return;
    try {
      const res = await fetch(location.pathname + "?t=" + Date.now(), { cache: "no-store" });
      const text = await res.text();
      const m = text.match(/Built ([0-9T:.\-Z]+)\./);
      if (m && m[1] !== stamp) {
        sessionStorage.setItem(KEY, String(window.scrollY));
        location.reload();
      }
    } catch {}
  }, 15000);
})();
</script>
`;
}

function card(r) {
  const last = r.attempts.at(-1);
  const chosen = r.attempts.find((a) => path.basename(a.file) === r.chosen) ?? last;
  return `<div class="card">
<img src="${esc(r.final)}" alt="${esc(r.shot)}" loading="lazy" onclick="z(this.src)">
<div class="body">
<div class="row"><h3>${esc(r.shot)}</h3><span class="pill ${r.passed ? "pass" : "fail"}">${r.passed ? "PASS" : "FAIL"} ${pct(r.score)}</span></div>
<p class="meta">${esc(r.group ?? "")} · ${esc(r.aspect_ratio)} · ${r.attempts.length} attempt${r.attempts.length === 1 ? "" : "s"} · ${esc(r.model)}${r.install ? ` · installs to <code>${esc(path.basename(r.install))}</code>` : ""}</p>
<table>${chosen.anchors
    .slice()
    .sort((a, b) => b.weight - a.weight)
    .map((a) => `<tr><td class="d">${bar(a.score)}</td><td class="w">${a.weight}</td><td>${esc(a.label)}</td></tr>`)
    .join("")}</table>
<details><summary>Verifier notes</summary>
<p class="meta">${esc(chosen.overall)}</p>
${chosen.anchors
    .map((a) => `<p class="obs"><strong>${esc(a.id)}</strong> · ${a.score}/5<br>ref: ${esc(a.reference)}<br>got: ${esc(a.candidate)}</p>${a.correction ? `<p class="corr">${esc(a.correction)}</p>` : ""}`)
    .join("")}
</details>
${attemptsBlock(r)}
</div></div>`;
}

function attemptsBlock(r) {
  if (r.attempts.length < 2) return "";
  return `<details><summary>All ${r.attempts.length} attempts</summary><div class="grid" style="grid-template-columns:repeat(${r.attempts.length},1fr);margin-top:10px">
${r.attempts.map((a) => `<figure style="margin:0"><img src="${esc(a.file)}" style="width:100%;border-radius:6px;border:1px solid var(--line)" loading="lazy" onclick="z(this.src)"><figcaption class="meta">#${a.n} · ${pct(a.score)}${a.pass ? " ✓" : ""}</figcaption></figure>`).join("")}
</div></details>`;
}
