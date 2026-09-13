#!/usr/bin/env node
import { readFile, writeFile, readdir, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadPack, findShot, allShots, refSource, DEFAULT_VERIFIER, applyVariant } from "../src/pack.mjs";
import { renderShot } from "../src/pipeline.mjs";
import { buildSheetPrompt } from "../src/prompt.mjs";
import { wavespeedRun, wavespeedUpload, download } from "../src/wavespeed.mjs";
import { verify, parseModel } from "../src/verify.mjs";
import { writeReport } from "../src/report.mjs";
import { bakeoff } from "../src/bakeoff.mjs";
import { triage, chooseReferences } from "../src/triage.mjs";
import { compose, writeSheet } from "../src/compose.mjs";
import { renderCasting, registerCastingSheet, CASTING_LABEL } from "../src/casting.mjs";

const root = path.resolve(fileURLToPath(import.meta.url), "../../..");

const USAGE = `character-studio — generate images of a real person that actually look like them

  triage   <dir>                  classify candidate photos, recommend a reference set
  ingest   <pack> <dir|file...>   add photographs to the pack, upload them, register them
  refs     <pack>                 upload refs/ to the CDN and write the urls into character.json
  shot     <pack> <id...>         render named shots, verify each, retry with the verifier's notes
  gallery  <pack> [--group g]     render every shot in the pack
  sheet    <pack>                 render the character sheet as one image, one prompt
  compose  <pack> [--only a,b]    render every sheet panel separately, lay out as html
  casting  <pack>                 render the four-frame casting sheet and register it as a reference
  verify   <pack> <image>         score one existing image against the pack, no generation
  install  <pack>                 copy passing renders to the "install" path each shot declares
  report   <pack>                 rebuild the HTML contact sheet from the json reports
  bakeoff  <pack> <shot>          run one shot through several image models and score each

Flags:
  --out <dir>         where renders and json reports go (default <pack>/out)
  --web <dir>         also write the html report here, e.g. a dev server public dir
  --group <name>      gallery only: render one group from shots.json
  --max <n>           gallery only: stop after n shots
  --only-failed       gallery only: skip shots whose last report passed
  --verifier <model>  override the pack's verifier
  --env-file <path>   file to read the api key from
  --triager <model>   triage only: classifier model (default gemini://gemini-3.8-flash)\n  --per-slot <n>      triage only: photos to keep per framing/angle/beard slot (default 2)\n  --role <name>       ingest only: role to record for the new references\n  --notes <text>      ingest only: notes to record for the new references\n  --models <a,b,c>    bakeoff only: comma-separated model ids\n  --only <a,b>        compose only: render just these panel groups\n  --label <name>      sheet only: output basename (default character-sheet-<model>)\n  --variant <id>      sheet only: variant to apply (default from sheetVariant)\n  --model <id>        sheet only: image model (default google/nano-banana-pro/edit)
  --resolution <r>    sheet only: 1k, 2k or 4k (default 4k)
  --force             install: copy renders that did not pass; compose: redo a passing panel
  --quiet             do not print the verifier banner

The verifier model is "<provider>://<model>" — openrouter:// (default) or gemini://.
Needs:  the wavespeed CLI logged in, and OPENROUTER_API_KEY (or GEMINI_API_KEY) reachable.`;

const argv = process.argv.slice(2);
const cmd = argv.shift();
const flags = {};
const args = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) {
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) { flags[key] = next; i++; } else flags[key] = true;
  } else args.push(argv[i]);
}

const log = (m) => process.stdout.write(`${m}\n`);

/** Declared above the top-level await main(), or the TDZ bites. */
const BAKEOFF_MODELS = [
  "google/nano-banana-pro/edit",
  "bytedance/seedream-v5.0-pro/edit",
  "openai/gpt-image-2/edit",
  "wavespeed-ai/flux-2-max/edit",
  "wavespeed-ai/qwen-image-2.0-pro/edit",
];


/** Resolves the verifier key for whichever provider the pack's model names. */
async function apiKey(character) {
  const { provider } = parseModel(flags.verifier ?? character.verification?.model ?? DEFAULT_VERIFIER);
  const varName = provider === "gemini" ? "GEMINI_API_KEY" : "OPENROUTER_API_KEY";

  const files = [flags["env-file"], process.env.CHARACTER_STUDIO_ENV, path.join(root, ".env.local"), path.join(root, ".env")];
  if (process.env[varName]) return { key: process.env[varName], varName };
  for (const p of files) {
    if (!p || !existsSync(p)) continue;
    const m = (await readFile(p, "utf8")).match(new RegExp(`^(?:export\\s+)?${varName}\\s*=\\s*(.+)$`, "m"));
    if (m) {
      const raw = m[1].trim();
      const key = /^["']/.test(raw) ? raw.replace(/^["']|["']$/g, "") : raw.replace(/\s+#.*$/, "").trim();
      return { key, varName };
    }
  }
  throw new Error(
    `${varName} not set. Export it, or pass --env-file <path>, or set CHARACTER_STUDIO_ENV to a file that defines it.`,
  );
}

const packDir = (p) => path.resolve(p.includes("/") ? p : path.join(root, "characters", p));
const outDir = (pack) => path.resolve(flags.out ?? path.join(pack.dir, "out"));
/** Second copy of the report, somewhere a dev server already serves. */
const webDir = (pack) => {
  const d = flags.web ?? pack.character.report_web_dir;
  return d ? path.resolve(root, d) : undefined;
};
/**
 * A page served at /character-studio without a trailing slash resolves its
 * relative image urls against /, so every image 404s. A base href fixes it.
 */
const webBase = (pack) => {
  const d = flags.web ?? pack.character.report_web_dir;
  if (!d) return undefined;
  const m = /public\/(.+)$/.exec(d.replace(/\/+$/, ""));
  return m ? `/${m[1]}/` : undefined;
};

try {
  await main();
} catch (err) {
  process.stderr.write(`\nerror: ${err.message}\n`);
  process.exit(1);
}

async function main() {
  if (!cmd || cmd === "help" || flags.help) return log(USAGE);
  if (cmd === "triage") return cmdTriage(args[0]);
  const dir = packDir(args[0] ?? "");
  if (!existsSync(dir)) throw new Error(`No character pack at ${dir}`);

  if (cmd === "refs") return cmdRefs(dir);
  if (cmd === "ingest") return cmdIngest(dir, args.slice(1));

  const pack = await loadPack(dir);
  pack.character.verification ??= {};
  if (flags.verifier) pack.character.verification.model = flags.verifier;
  pack.character.verification.model ??= DEFAULT_VERIFIER;
  const { key, varName } = await apiKey(pack.character);
  if (!flags.quiet) log(`verifier: ${pack.character.verification.model}  (${varName})`);

  if (cmd === "shot") return cmdShots(pack, key, args.slice(1));
  if (cmd === "gallery") return cmdGallery(pack, key);
  if (cmd === "sheet") return cmdSheet(pack, key);
  if (cmd === "compose") return cmdCompose(pack, key);
  if (cmd === "casting") return cmdCasting(pack, key);
  if (cmd === "verify") return cmdVerify(pack, key, args[1]);
  if (cmd === "bakeoff") return cmdBakeoff(pack, key, args[1]);
  if (cmd === "install") return cmdInstall(pack);
  if (cmd === "report") return writeReport(pack, outDir(pack), webDir(pack), webBase(pack)).then((f) => log(`wrote ${f}`));
  throw new Error(`Unknown command "${cmd}"\n\n${USAGE}`);
}

async function cmdRefs(dir) {
  const refsDir = path.join(dir, "refs");
  const charFile = path.join(dir, "character.json");
  const character = JSON.parse(await readFile(charFile, "utf8"));
  const files = character.references.map((r) => path.join(refsDir, r.file));
  for (const f of files) if (!existsSync(f)) throw new Error(`Missing reference file ${f}`);
  log(`uploading ${files.length} references…`);
  const urls = await wavespeedUpload(files);
  for (const ref of character.references) ref.url = urls[ref.file];
  await writeFile(charFile, `${JSON.stringify(character, null, 2)}\n`);
  log(`wrote ${files.length} urls into ${path.relative(root, charFile)}`);
}

/**
 * Copies photographs into the pack, uploads them and registers them.
 *
 * Source does not matter. The Google Photos Picker API cannot enumerate or
 * filter a library by person, so there is no way to pull "every photo of X"
 * from it. Any folder works instead: a Google Takeout export, AirDrop, a
 * download, a phone dump.
 */
async function cmdTriage(dir) {
  if (!dir) throw new Error("triage needs a directory of candidate photos");
  const abs = path.resolve(dir);
  if (!existsSync(abs)) throw new Error(`No such directory: ${abs}`);
  const model = flags.triager ?? "gemini://gemini-3.8-flash";
  const { provider } = parseModel(model);
  const varName = provider === "gemini" ? "GEMINI_API_KEY" : "OPENROUTER_API_KEY";
  const { key } = await apiKey({ verification: { model } });
  log(`triage: ${abs}\ntriager: ${model}  (${varName})\n`);

  const rows = await triage({ dir: abs, model, apiKey: key, log });
  const pick = chooseReferences(rows, { perSlot: Number(flags["per-slot"] ?? 2) });

  log(`\n${pick.usable}/${pick.total} usable, ${pick.slots} distinct framing/angle/beard combinations`);
  log(`\nRecommended reference set (${pick.chosen.length}):\n`);
  for (const r of pick.chosen) {
    log(`  ${r.file.padEnd(34)} ${String(r.slot).padEnd(28)} sharp ${r.sharpness}  face ${r.face_size}%  ${r.note ?? ""}`);
  }
  const listFile = path.join(abs, "chosen.txt");
  await writeFile(listFile, pick.chosen.map((r) => path.join(abs, r.file)).join("\n") + "\n");
  log(`\nwrote ${path.relative(root, listFile)} and triage.json`);
  log(`Next: character-studio ingest <pack> $(cat ${path.relative(root, listFile)} | tr '\\n' ' ')`);
}

async function cmdIngest(dir, inputs) {
  if (!inputs.length) throw new Error("ingest needs a directory or one or more image files");
  const { copyFile, stat } = await import("node:fs/promises");
  const refsDir = path.join(dir, "refs");
  await mkdir(refsDir, { recursive: true });

  const found = [];
  for (const input of inputs) {
    const abs = path.resolve(input);
    if (!existsSync(abs)) throw new Error(`No such path: ${abs}`);
    if ((await stat(abs)).isDirectory()) {
      for (const f of (await readdir(abs)).sort()) {
        if (/\.(jpe?g|png|webp|heic)$/i.test(f)) found.push(path.join(abs, f));
      }
    } else found.push(abs);
  }
  if (!found.length) throw new Error("No jpg, png, webp or heic files found");

  const charFile = path.join(dir, "character.json");
  const character = JSON.parse(await readFile(charFile, "utf8"));
  const known = new Set(character.references.map((r) => r.file));

  const added = [];
  for (const src of found) {
    let name = path.basename(src);
    while (known.has(name)) name = `${path.parse(name).name}-2${path.parse(name).ext}`;
    await copyFile(src, path.join(refsDir, name));
    known.add(name);
    added.push(name);
  }
  log(`copied ${added.length} file${added.length === 1 ? "" : "s"} into ${path.relative(root, refsDir)}`);

  const urls = await wavespeedUpload(added.map((f) => path.join(refsDir, f)));
  for (const f of added) {
    character.references.push({
      file: f,
      role: flags.role ?? "unsorted",
      url: urls[f],
      notes: flags.notes ?? "Ingested. Set role and notes, then decide which shots should use it.",
    });
  }
  await writeFile(charFile, `${JSON.stringify(character, null, 2)}\n`);
  log(`registered ${added.length} reference${added.length === 1 ? "" : "s"} in ${path.relative(root, charFile)}`);
  log(`\nNext: set the role and notes for each, then add the good ones to a shot's "refs".`);
}

async function cmdShots(pack, key, ids) {
  const out = outDir(pack);
  const results = [];
  for (const id of ids) {
    const shot = findShot(pack, id);
    log(`\n${shot.id}  [${shot.group ?? "shot"}]  ${shot.aspect_ratio}`);
    results.push(await renderShot({ pack, shot, outDir: out, apiKey: key, log }));
  }
  summarise(results);
  log(`\n${await writeReport(pack, out, webDir(pack), webBase(pack))}`);
}

// The casting sheet is the only render that is fed back into later renders, so
// it registers itself in character.json on a pass. A failing sheet is left on
// disk and NOT registered: a reference carrying a wrong face would push that
// face into every shot that cites it, and the fault would read as model drift.
async function cmdCasting(pack, key) {
  const out = outDir(pack);
  await mkdir(out, { recursive: true });
  const label = flags.label ?? CASTING_LABEL;
  log(`\n${label}  [casting]  1:1`);
  const result = await renderCasting({
    pack,
    outDir: out,
    apiKey: key,
    label,
    model: flags.model,
    resolution: flags.resolution,
    variant: flags.variant ?? pack.character.sheetVariant,
    log,
  });
  summarise([result]);
  if (result.best.pass) {
    const sheet = await registerCastingSheet({ pack, file: result.finalFile, score: result.best.score });
    log(`\nregistered as the casting sheet: ${sheet.file}  ${(sheet.score * 100).toFixed(1)}%`);
    log(`  ${sheet.url}`);
  } else {
    log(`\nnot registered — a casting sheet below the pass mark would carry its faults into every shot that references it.`);
  }
  log(`\n${await writeReport(pack, out, webDir(pack), webBase(pack))}`);
}

async function cmdGallery(pack, key) {
  const out = outDir(pack);
  let shots = allShots(pack);
  if (flags.group) shots = shots.filter((s) => s.group === flags.group);
  if (flags["only-failed"]) {
    const keep = [];
    for (const s of shots) {
      const rf = path.join(out, `${s.id}.report.json`);
      if (!existsSync(rf)) { keep.push(s); continue; }
      try {
        if (!JSON.parse(await readFile(rf, "utf8")).passed) keep.push(s);
      } catch { keep.push(s); }
    }
    shots = keep;
  }
  if (flags.max) shots = shots.slice(0, Number(flags.max));
  log(`rendering ${shots.length} shots into ${path.relative(root, out)}`);
  const results = [];
  for (const shot of shots) {
    log(`\n${shot.id}  [${shot.group ?? "shot"}]  ${shot.aspect_ratio}`);
    try {
      results.push(await renderShot({ pack, shot, outDir: out, apiKey: key, log }));
    } catch (err) {
      log(`  FAILED: ${err.message}`);
    }
  }
  summarise(results);
  log(`\n${await writeReport(pack, out, webDir(pack), webBase(pack))}`);
}

async function cmdSheet(pack, key) {
  const out = outDir(pack);
  await mkdir(out, { recursive: true });
  const board = await readFile(path.join(pack.dir, "sheet-board.md"), "utf8");
  const variantId = flags.variant ?? pack.character.sheetVariant;
  const character = applyVariant(pack.character, variantId);
  if (variantId) log(`variant: ${variantId}`);
  // Seedream accepts 10 reference images, the Google models 14. Cap at 10 so a
  // model swap does not fail on the reference count alone.
  const refFiles = pack.character.references.slice(0, 10).map((r) => r.file);
  const model = flags.model ?? "google/nano-banana-pro/edit";

  // Name the outputs after the model. Two sheet runs used to write the same
  // character-sheet.report.json and silently overwrite each other, so the
  // contact sheet showed whichever finished last.
  const label = flags.label ?? `character-sheet-${model.split("/")[1] ?? model}`.replace(/[^a-z0-9-]+/gi, "-");
  const maxAttempts = pack.character.verification?.max_attempts ?? 3;
  const attempts = [];
  for (let n = 1; n <= maxAttempts; n++) {
    log(`character sheet — attempt ${n}/${maxAttempts} with ${model}`);
    const prompt = buildSheetPrompt({
      character,
      board,
      corrections: attempts.at(-1)?.corrections ?? [],
    });
    const { urls } = await wavespeedRun(model, {
      prompt,
      images: refFiles.map((f) => pack.refUrl(f)),
      aspect_ratio: "16:9",
      resolution: flags.resolution ?? "4k",
      output_format: "jpeg",
    });
    const file = path.join(out, `${label}.attempt-${n}.jpg`);
    await download(urls[0], file);
    log(`  verifying…`);
    const result = await verify({
      character,
      candidate: file,
      refSources: refFiles.slice(0, 4).map((f) => refSource(pack, f)),
      model: pack.character.verification?.model,
      apiKey: key,
    });
    attempts.push({ n, file, ...result });
    log(`  score ${(result.score * 100).toFixed(1)}%  ${result.pass ? "PASS" : "FAIL"}`);
    if (result.pass) break;
  }
  const best = attempts.reduce((a, b) => (b.score > a.score ? b : a));
  const { copyFile } = await import("node:fs/promises");
  await copyFile(best.file, path.join(out, `${label}.jpg`));
  await writeFile(
    path.join(out, `${label}.report.json`),
    JSON.stringify(
      { shot: label, group: "sheet", model, aspect_ratio: "16:9", refs: refFiles,
        final: `${label}.jpg`, passed: best.pass, score: best.score,
        attempts: attempts.map((a) => ({ n: a.n, file: path.basename(a.file), score: a.score, pass: a.pass,
          same_person: a.same_person, overall: a.overall, criticalFailures: a.criticalFailures, anchors: a.anchors })) },
      null, 2,
    ),
  );
  log(`\nbest: ${(best.score * 100).toFixed(1)}%  →  ${path.relative(root, path.join(out, `${label}.jpg`))}`);
  log(await writeReport(pack, out, webDir(pack), webBase(pack)));
}

async function cmdCompose(pack, key) {
  const out = path.resolve(flags.out ?? path.join(pack.dir, "sheet"));
  const only = flags.only ? String(flags.only).split(",") : undefined;
  const file = await compose({ pack, outDir: out, apiKey: key, only, force: flags.force, log });
  const web = webDir(pack);
  if (web) {
    const published = await writeSheet({ pack, outDir: out, webDir: web });
    log(`\n${published}`);
  }
  log(`\n${file}`);
}

async function cmdVerify(pack, key, image) {
  if (!image) throw new Error("verify needs an image path or url");
  const result = await verify({
    character: pack.character,
    candidate: /^https?:\/\//.test(image) ? image : path.resolve(image),
    refSources: pack.character.references.slice(0, 4).map((r) => refSource(pack, r.file)),
    model: pack.character.verification?.model,
    apiKey: key,
  });
  log(`\n${image}`);
  log(`same person: ${result.same_person}   score: ${(result.score * 100).toFixed(1)}%   ${result.pass ? "PASS" : "FAIL"}\n`);
  for (const a of result.anchors.sort((x, y) => y.weight - x.weight)) {
    log(`  ${String(a.score).padStart(2)}/5  w${a.weight}  ${a.label}`);
    log(`         ref: ${a.reference}`);
    log(`         got: ${a.candidate}`);
    if (a.correction) log(`         →   ${a.correction}`);
  }
  log(`\n${result.overall}`);
}

async function cmdInstall(pack) {
  const out = outDir(pack);
  const { copyFile } = await import("node:fs/promises");
  let n = 0;
  for (const f of await readdir(out)) {
    if (!f.endsWith(".report.json")) continue;
    const rep = JSON.parse(await readFile(path.join(out, f), "utf8"));
    if (!rep.install) continue;
    if (!rep.passed && !flags.force) { log(`skip ${rep.shot} — did not pass (use --force)`); continue; }
    const dest = path.join(root, rep.install);
    await copyFile(path.join(out, rep.final), dest);
    log(`installed ${rep.shot} → ${rep.install}`);
    n++;
  }
  log(`\n${n} image${n === 1 ? "" : "s"} installed`);
}

async function cmdBakeoff(pack, key, shotId) {
  if (!shotId) throw new Error("bakeoff needs a shot id");
  const shot = findShot(pack, shotId);
  const models = flags.models ? String(flags.models).split(",") : BAKEOFF_MODELS;
  log(`\nbakeoff: ${shot.id} across ${models.length} models\n`);
  const rows = await bakeoff({ pack, shot, models, outDir: outDir(pack), apiKey: key, log });
  log(`\n${"-".repeat(64)}`);
  for (const r of rows) {
    log(`  ${(r.score * 100).toFixed(1).padStart(5)}%  ${r.pass ? "PASS" : "fail"}  ${r.model}${r.error ? `  (${r.error})` : ""}`);
  }
}

function summarise(results) {
  log(`\n${"─".repeat(64)}`);
  for (const r of results) {
    log(`  ${r.best.pass ? "PASS" : "FAIL"}  ${(r.best.score * 100).toFixed(1).padStart(5)}%  ${r.shot.id}`);
  }
  const passed = results.filter((r) => r.best.pass).length;
  log(`  ${passed}/${results.length} passed`);
}
