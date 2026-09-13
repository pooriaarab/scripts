import { readFile, writeFile, mkdir, copyFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { renderShot } from "./pipeline.mjs";

/**
 * Builds a character sheet by rendering each panel separately and laying the
 * results out as HTML.
 *
 * One prompt for a whole 16:9 board asks the image model to do two jobs at once:
 * hold a likeness across twenty small faces, and typeset. It does neither well.
 * Faces came out at a fraction of the frame, and labels came back as "POORIA
 * ARABS", "TURNARUNE" and "BEAR DENSITY MAP".
 *
 * Composing separates the jobs. Every panel is a full-resolution render that
 * goes through the same verify-and-retry loop as a portrait, so each face gets
 * the quality a single portrait gets. The text is real text in a real document,
 * so it cannot garble at all.
 */
export async function compose({ pack, outDir, apiKey, only, log = () => {} }) {
  const spec = JSON.parse(await readFile(path.join(pack.dir, "sheet-panels.json"), "utf8"));
  await mkdir(outDir, { recursive: true });

  const groups = only ? spec.groups.filter((g) => only.includes(g.id)) : spec.groups;
  const total = groups.reduce((n, g) => n + g.panels.length, 0);
  log(`composing ${total} panels across ${groups.length} groups\n`);

  let done = 0;
  for (const group of groups) {
    log(`${group.title}`);
    for (const panel of group.panels) {
      done++;
      const shot = { ...spec.defaults, ...panel, group: `sheet-${group.id}` };
      const reportFile = path.join(outDir, `${shot.id}.report.json`);
      if (existsSync(reportFile) && !only) {
        const prev = JSON.parse(await readFile(reportFile, "utf8"));
        if (prev.passed) { log(`  [${done}/${total}] ${panel.id} — already passed, skipping`); continue; }
      }
      log(`  [${done}/${total}] ${panel.id}`);
      try {
        const { best } = await renderShot({ pack, shot, outDir, apiKey, log: (m) => log(`    ${m.trim()}`) });
        log(`    ${(best.score * 100).toFixed(1)}%  ${best.pass ? "PASS" : "fail"}`);
      } catch (err) {
        log(`    failed: ${err.message}`);
      }
    }
  }

  return writeSheet({ pack, spec, outDir });
}

/** Lays the rendered panels out as a self-contained HTML sheet. */
export async function writeSheet({ pack, spec, outDir, webDir }) {
  spec ??= JSON.parse(await readFile(path.join(pack.dir, "sheet-panels.json"), "utf8"));
  const dest = webDir ?? outDir;
  await mkdir(dest, { recursive: true });

  if (dest !== outDir) {
    for (const f of await readdir(outDir)) {
      if (/\.(jpg|jpeg|png|webp)$/i.test(f)) await copyFile(path.join(outDir, f), path.join(dest, f));
    }
  }

  const scores = {};
  for (const f of await readdir(outDir)) {
    if (!f.endsWith(".report.json")) continue;
    const r = JSON.parse(await readFile(path.join(outDir, f), "utf8"));
    scores[r.shot] = r;
  }

  const file = path.join(dest, "sheet.html");
  await writeFile(file, sheetHtml(pack.character, spec, scores));
  return file;
}

const esc = (s) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

function panelImg(p, scores) {
  const r = scores[p.id];
  const score = r ? `${(r.score * 100).toFixed(0)}%` : "";
  const cls = r?.passed ? "ok" : r ? "warn" : "none";
  // A panel with no report has not rendered yet. Show a placeholder rather than
  // a broken image icon, so a sheet mid-run reads as "pending", not "failed".
  const body = r
    ? `<img src="${esc(r.final)}" alt="${esc(p.label ?? p.id)}" loading="lazy" onclick="z(this.src)">`
    : `<div class="pending" style="aspect-ratio:${esc((p.aspect_ratio ?? "1:1").replace(":", "/"))}"><span>rendering…</span></div>`;
  return `<figure class="panel">
  ${body}
  <figcaption>${esc(p.label ?? p.id)}<span class="sc ${cls}">${score}</span></figcaption>
</figure>`;
}

function sheetHtml(c, spec, scores) {
  const all = spec.groups.flatMap((g) => g.panels.map((p) => scores[p.id])).filter(Boolean);
  const passed = all.filter((r) => r.passed).length;
  const mean = all.length ? all.reduce((s, r) => s + r.score, 0) / all.length : 0;
  const palette = c.wardrobe?.palette ?? [];

  return `<!doctype html>
<meta charset="utf-8">
<title>${esc(c.name)} — character reference</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--ink:#15130f;--mut:#6b655c;--line:#ded8cd;--bg:#f7f5f0;--card:#fff;--ok:#2e7d4f;--warn:#b07d2e}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 ui-sans-serif,-apple-system,"Segoe UI",Inter,sans-serif}
.sheet{max-width:1680px;margin:0 auto;padding:40px 28px 100px}
header{display:flex;flex-wrap:wrap;gap:12px;justify-content:space-between;align-items:flex-end;border-bottom:2px solid var(--ink);padding-bottom:14px;margin-bottom:36px}
h1{font-size:30px;margin:0;letter-spacing:.06em;font-weight:600;text-transform:uppercase}
h1 span{font-weight:300;letter-spacing:.14em}
.stat{font-size:12px;color:var(--mut);text-align:right;line-height:1.7}
section{margin-bottom:44px}
h2{font-size:12px;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);font-weight:600;margin:0 0 4px;
   border-bottom:1px solid var(--line);padding-bottom:8px;display:flex;flex-wrap:wrap;gap:8px;justify-content:space-between}
h2 em{font-style:normal;font-weight:400;letter-spacing:.02em;text-transform:none}
.panels{display:grid;gap:16px;margin-top:16px}
.row{grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
.grid{grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
.hero{grid-template-columns:minmax(0,420px)}
.panel{margin:0;background:var(--card);border:1px solid var(--line);border-radius:4px;overflow:hidden}
.panel img{width:100%;display:block;background:#eee;cursor:zoom-in}
.panel figcaption{padding:8px 10px;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--mut);
  display:flex;justify-content:space-between;gap:6px}
.sc{font-variant-numeric:tabular-nums}
.sc.ok{color:var(--ok)} .sc.warn{color:var(--warn)} .sc.none{color:#c3bdb2}
.pending{width:100%;background:repeating-linear-gradient(45deg,#f0ece4,#f0ece4 8px,#e8e3d9 8px,#e8e3d9 16px);
  display:flex;align-items:center;justify-content:center}
.pending span{font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:#a39c90}
.two{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:40px}
.swatches{display:grid;grid-template-columns:repeat(auto-fit,minmax(84px,1fr));gap:10px;margin-top:16px}
.sw{border:1px solid var(--line);border-radius:4px;overflow:hidden;background:#fff}
.sw i{display:block;height:64px}
.sw span{display:block;padding:6px 8px;font-size:10px;letter-spacing:.06em;text-transform:uppercase;color:var(--mut)}
table.anchors{width:100%;border-collapse:collapse;font-size:12px;margin-top:16px}
table.anchors td{padding:5px 8px 5px 0;border-bottom:1px solid var(--line);vertical-align:top}
table.anchors td.n{white-space:nowrap;color:var(--mut);font-variant-numeric:tabular-nums}
dialog{border:0;background:transparent;max-width:96vw;max-height:96vh;padding:0}
dialog::backdrop{background:rgba(20,18,15,.92)}
dialog img{max-width:96vw;max-height:96vh;display:block}
footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--line);font-size:11px;color:var(--mut)}
@media print{body{background:#fff}.sheet{max-width:none;padding:0}}
</style>
<div class="sheet">
<header>
  <h1>${esc(c.name)} <span>— character reference</span></h1>
  <div class="stat">
    Pack v${esc(c.version)} · ${esc(c.updated)}<br>
    ${passed}/${all.length} panels passed · mean ${(mean * 100).toFixed(1)}%<br>
    Verified against ${c.references.length} photographs by ${esc(c.verification.model)}
  </div>
</header>

${spec.groups
  .map(
    (g) => `<section>
  <h2>${esc(g.title)}<em>${esc(g.note ?? "")}</em></h2>
  <div class="panels ${esc(g.layout ?? "grid")}">
    ${g.panels.map((p) => panelImg(p, scores)).join("\n    ")}
  </div>
</section>`,
  )
  .join("\n")}

<section class="two">
  <div>
    <h2>06 · Palette</h2>
    <div class="swatches">
      ${palette.map((hex) => `<div class="sw"><i style="background:${esc(hex)}"></i><span>${esc(hex)}</span></div>`).join("\n      ")}
    </div>
  </div>
  <div>
    <h2>07 · Proportion</h2>
    <table class="anchors">
      <tr><td class="n">${c.calibration?.medians?.forehead_pct ?? "—"}%</td><td>Forehead, brow to hairline, of face height</td></tr>
      <tr><td class="n">${c.calibration?.medians?.face_width_pct ?? "—"}%</td><td>Cheekbone width, of face height</td></tr>
      <tr><td class="n">${c.calibration?.medians?.beard_cheek_pct ?? "—"}%</td><td>Beard coverage on the flat of the cheek</td></tr>
      <tr><td class="n">${c.calibration?.medians?.shoulder_heads ?? "—"}</td><td>Shoulder width, in head-widths</td></tr>
    </table>
  </div>
</section>

<section>
  <h2>08 · Identity lock<em>Ordered by how fast a wrong value reads as someone else</em></h2>
  <table class="anchors">
    ${c.anchors
      .slice()
      .sort((a, b) => b.weight - a.weight)
      .map((a) => `<tr><td class="n">w${a.weight}</td><td><strong>${esc(a.label)}</strong><br>${esc(a.check)}</td></tr>`)
      .join("\n    ")}
  </table>
</section>

<footer>
  Every panel is a separate render, verified against the real photographs and retried against its own faults.
  Scores are a likeness measure and are unreliable above about 75%, so a human check still decides.
  Built ${new Date().toISOString()}.
</footer>
</div>
<dialog id="lb" onclick="this.close()"><img id="lbi"></dialog>
<script>
function z(s){document.getElementById('lbi').src=s;document.getElementById('lb').showModal()}
(function () {
  const KEY = "cs-sheet-scroll";
  const y = sessionStorage.getItem(KEY);
  if (y) { window.scrollTo(0, Number(y)); sessionStorage.removeItem(KEY); }
  if (!document.querySelector(".pending")) return;   // nothing left to wait for
  setInterval(() => {
    if (document.getElementById("lb").open) return;
    sessionStorage.setItem(KEY, String(window.scrollY));
    location.reload();
  }, 20000);
})();
</script>
`;
}
