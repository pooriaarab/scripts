import { mkdir, writeFile, copyFile } from "node:fs/promises";
import path from "node:path";
import { buildPrompt } from "./prompt.mjs";
import { refSource, DEFAULT_VERIFIER, anchorsForShot, applyVariant, castingUrl } from "./pack.mjs";
import { wavespeedRun, download } from "./wavespeed.mjs";
import { verify } from "./verify.mjs";

/**
 * Generate one shot, verify it, and retry with the verifier's own corrections fed
 * back into the prompt. Returns the best attempt even when nothing passed, so a
 * near miss is still inspectable rather than lost.
 */
export async function renderShot({ pack, shot, outDir, apiKey, log = () => {} }) {
  const character = applyVariant(pack.character, shot.variant);
  const maxAttempts = character.verification?.max_attempts ?? 3;
  const verifyModel = character.verification?.model ?? DEFAULT_VERIFIER;
  const refFiles = shot.refs ?? character.references.slice(0, 4).map((r) => r.file);

  // A shot that sets `useCasting` gets the approved casting card as its first
  // reference, so the likeness travels as a picture rather than as prose. It is
  // first because an edit model weights the leading reference most heavily.
  //
  // The card goes to the IMAGE model only. It never joins refSources below,
  // because verification has to score against the real photographs: a generated
  // card scored against itself would confirm its own drift and every later shot
  // would inherit it.
  const refUrls = [
    ...(shot.useCasting ? [castingUrl(character)] : []),
    ...refFiles.map((f) => pack.refUrl(f)),
  ];

  await mkdir(outDir, { recursive: true });

  let corrections = [];
  const attempts = [];

  for (let n = 1; n <= maxAttempts; n++) {
    const prompt = buildPrompt({ character, shot, corrections });
    log(`  attempt ${n}/${maxAttempts} — generating with ${shot.model}`);

    // Seed, where the model has one. FLUX and Qwen expose it; seedream-v5 and
    // nano-banana-pro do not, so a fixed seed is not available on the models
    // that hold a likeness best. Where it works, a fixed base seed plus the
    // attempt number keeps a retry comparable instead of an unrelated reroll.
    const seed = shot.seed === undefined ? undefined : Number(shot.seed) + n - 1;
    const { urls } = await wavespeedRun(shot.model, {
      prompt,
      images: refUrls,
      aspect_ratio: shot.aspect_ratio,
      resolution: shot.resolution,
      output_format: shot.output_format,
      ...(seed === undefined ? {} : { seed }),
    });

    const ext = shot.output_format === "jpeg" ? "jpg" : shot.output_format;
    const file = path.join(outDir, `${shot.id}.attempt-${n}.${ext}`);
    await download(urls[0], file);

    log(`  attempt ${n} — verifying with ${verifyModel}`);
    const result = await verify({
      character: { ...character, anchors: anchorsForShot(character, shot) },
      candidate: file,
      refSources: refFiles.map((f) => refSource(pack, f)),
      model: verifyModel,
      apiKey,
      // Camera, expression and wardrobe are the parts of the brief the likeness
      // score cannot see. They go in separately so the verifier judges them
      // separately.
      brief: { framing: shot.framing, expression: shot.expression, wardrobe: shot.wardrobe },
    });

    attempts.push({ n, file, prompt, ...result });
    log(
      `  attempt ${n} — score ${(result.score * 100).toFixed(1)}%  ${result.pass ? "PASS" : "FAIL"}` +
        (result.criticalFailures.length ? `  (critical: ${result.criticalFailures.join(", ")})` : ""),
    );

    if (result.pass) break;
    // One correction per round. Feeding every fault back made the model trade one
    // for another and the score bounced instead of climbing.
    corrections = result.weakest ? [result.weakest.correction] : result.corrections.slice(0, 1);
    if (result.brief_followed === false) log(`  attempt ${n} — brief: ${result.brief_note}`);
    if (result.weakest) log(`  attempt ${n} — next round targets: ${result.weakest.id}`);
  }

  // A passing attempt always beats a failing one, whatever the scores say, and a
  // tie goes to the later attempt because it is the one that carried a
  // correction. Ranking on score alone with a strict > silently published a
  // failed render: a back view scored 1.0 on both attempts, attempt 1 was judged
  // a different person and attempt 2 was not, and the tie handed it to attempt 1.
  const best = attempts.reduce((a, b) => {
    if (a.pass !== b.pass) return b.pass ? b : a;
    return b.score >= a.score ? b : a;
  });
  const finalExt = shot.output_format === "jpeg" ? "jpg" : shot.output_format;
  const finalFile = path.join(outDir, `${shot.id}.${finalExt}`);
  await copyFile(best.file, finalFile);

  await writeFile(
    path.join(outDir, `${shot.id}.report.json`),
    JSON.stringify(
      {
        shot: shot.id,
        group: shot.group,
        model: shot.model,
        aspect_ratio: shot.aspect_ratio,
        refs: refFiles,
        chosen: path.basename(best.file),
        final: path.basename(finalFile),
        install: shot.install ?? null,
        passed: best.pass,
        score: best.score,
        attempts: attempts.map((a) => ({
          n: a.n,
          file: path.basename(a.file),
          score: a.score,
          pass: a.pass,
          same_person: a.same_person,
          overall: a.overall,
          criticalFailures: a.criticalFailures,
          // Recorded because a "brief" failure is otherwise invisible after the
          // run: the report showed a critical failure with no way to read what
          // the verifier actually objected to.
          brief_followed: a.brief_followed,
          brief_note: a.brief_note,
          anchors: a.anchors.map(({ id, label, weight, score, reference, candidate, correction }) => ({
            id,
            label,
            weight,
            score,
            reference,
            candidate,
            correction,
          })),
        })),
      },
      null,
      2,
    ),
  );

  return { shot, best, attempts, finalFile };
}
