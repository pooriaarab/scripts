import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { buildPrompt } from "./prompt.mjs";
import { wavespeedRun, download } from "./wavespeed.mjs";
import { verify } from "./verify.mjs";
import { refSource, DEFAULT_VERIFIER } from "./pack.mjs";

/**
 * Runs one shot through several image models and scores each result with the
 * same verifier and the same prompt.
 *
 * Model choice turned out to matter more than any amount of prompt work, and
 * there is no way to know which model holds a given face without measuring. One
 * attempt each, no retries: this compares models, it does not produce finals.
 */
export async function bakeoff({ pack, shot, models, outDir, apiKey, log = () => {} }) {
  const { character } = pack;
  const verifyModel = character.verification?.model ?? DEFAULT_VERIFIER;
  const refFiles = shot.refs ?? character.references.slice(0, 3).map((r) => r.file);
  const refUrls = refFiles.map((f) => pack.refUrl(f));
  const refSources = refFiles.map((f) => refSource(pack, f));
  const prompt = buildPrompt({ character, shot });

  await mkdir(outDir, { recursive: true });
  const rows = [];

  for (const model of models) {
    const slug = model.replace(/[^a-z0-9]+/gi, "-");
    try {
      log(`  ${model} — generating`);
      const { urls } = await wavespeedRun(model, {
        prompt,
        images: refUrls,
        aspect_ratio: shot.aspect_ratio,
        resolution: shot.resolution,
        output_format: "jpeg",
      });
      const file = path.join(outDir, `bakeoff.${shot.id}.${slug}.jpg`);
      await download(urls[0], file);

      const result = await verify({ character, candidate: file, refSources, model: verifyModel, apiKey });
      rows.push({ model, file: path.basename(file), ...result });
      log(
        `  ${model} — ${(result.score * 100).toFixed(1)}%  ${result.pass ? "PASS" : "FAIL"}` +
          (result.criticalFailures.length ? `  (${result.criticalFailures.join(", ")})` : ""),
      );
    } catch (err) {
      log(`  ${model} — error: ${err.message}`);
      rows.push({ model, error: err.message, score: 0 });
    }
  }

  rows.sort((a, b) => b.score - a.score);
  await writeFile(
    path.join(outDir, `bakeoff.${shot.id}.json`),
    JSON.stringify({ shot: shot.id, refs: refFiles, verifier: verifyModel, results: rows }, null, 2),
  );
  return rows;
}
