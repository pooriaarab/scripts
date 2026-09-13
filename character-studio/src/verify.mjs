import path from "node:path";
import { toInlineImage } from "./image.mjs";

/**
 * Scores a candidate render against the pack's anchors with a vision model.
 *
 * The verifier never sees the prompt that produced the image. It only sees the
 * reference photographs, the candidate, and the anchor definitions. That keeps it
 * from grading the intent instead of the result.
 *
 * Two backends, because a dead billing account on one should not stop the loop:
 *   openrouter://<model>   (default)
 *   gemini://<model>
 */
export async function verify({ character, candidate, refSources, model, apiKey, brief }) {
  const { provider, name } = parseModel(model);
  const instructions = buildInstructions(character, refSources.length, brief);

  const images = [];
  for (const src of refSources) images.push({ label: `REFERENCE: ${path.basename(src)}`, ...(await toInlineImage(src, { maxEdge: 1400 })) });
  // The candidate goes in larger than the references. A downscaled candidate hid a
  // hard-edged composite beard that was obvious at full size.
  images.push({ label: "CANDIDATE:", ...(await toInlineImage(candidate, { maxEdge: 2000 })) });

  const withBrief = Boolean(brief && Object.values(brief).some(Boolean));
  const raw =
    provider === "gemini"
      ? await callGemini({ name, apiKey, instructions, images, withBrief })
      : await callOpenRouter({ name, apiKey, instructions, images, withBrief });

  return score(character, raw, withBrief);
}

export function parseModel(model) {
  const m = /^(\w+):\/\/(.+)$/.exec(model);
  if (m) return { provider: m[1], name: m[2] };
  return { provider: "openrouter", name: model };
}

function buildInstructions(character, refCount, brief) {
  return [
    `You are a forensic likeness examiner. Your job is to catch impostors, not to confirm a brief.`,
    ``,
    `The first ${refCount} images are REFERENCE photographs of one real person. The last image is a CANDIDATE render that claims to be the same person.`,
    ``,
    `## HOW TO WORK`,
    ``,
    `Work in this order for every anchor, and do not skip a step:`,
    `1. Look at the REFERENCE images and write down what you actually see for that trait. Describe the photographs, not the anchor text.`,
    `2. Look at the CANDIDATE and write down what you actually see for that trait, as if you had never read the anchor text.`,
    `3. Only then compare the two and score.`,
    ``,
    `The MUST and NEVER lines below tell you which trait to examine. They are NOT evidence that the candidate has that trait. Never restate a MUST line as your observation. If your "candidate" note reads like a paraphrase of the MUST line, you have not looked.`,
    ``,
    `## MEASUREMENTS — do these before you score`,
    ``,
    `Estimate each of these on BOTH the reference and the candidate, and put the numbers in your observations:`,
    `- Forehead height from brow line to hairline, as a percentage of face height from chin to hairline.`,
    `- Face width at the cheekbones divided by face height from chin to hairline.`,
    `- Shoulder width measured in head-widths.`,
    `- Beard coverage on the flat of the cheek, as a percentage of that area covered by hair.`,
    `- Visible forehead skin above the outer end of each eyebrow: present or covered by hair.`,
    `A gap of more than about 15 percent on any of these is a real difference, not a rounding error. Say so.`,
    ``,
    `## SCORING`,
    ``,
    `5 = you cannot name a specific visible difference from the reference on this trait.`,
    `4 = you CAN name a specific visible difference, but it is small enough that a stranger would not notice.`,
    `3 = a visible deviation that weakens the likeness.`,
    `2 = clearly wrong. On this trait alone the candidate reads as a different person.`,
    `1 = violates the NEVER line outright.`,
    `0 = the trait is genuinely not visible in the candidate and cannot be judged. Use this sparingly.`,
    ``,
    `The score must follow the evidence, in both directions.`,
    `A score of 4 or below REQUIRES a named difference in the "correction" field. If your correction would only`,
    `say "maintain", "keep" or "continue" doing what the candidate already does, you have not found a difference,`,
    `and the honest score is 5. Withholding a point you cannot justify is as wrong as awarding one you cannot.`,
    `Equally, do not inflate. If the forehead, hairline, face width or beard density differs from the reference,`,
    `say so and score it down, however attractive the image is. Only likeness counts, never lighting or composition.`,
    ``,
    `## OUTPUT`,
    ``,
    `For each anchor return:`,
    `  id             — exactly as written below`,
    `  reference      — what you see in the REFERENCE photographs for this trait, with the numbers where they apply`,
    `  candidate      — what you see in the CANDIDATE for this trait, with the same numbers`,
    `  score          — 0 to 5`,
    `  correction     — for any score of 4 or below, one imperative sentence naming the SPECIFIC difference you`,
    `                   saw and the fix. It must describe a change. "Maintain X" and "keep X" are not corrections;`,
    `                   if that is all you can write, the score was 5. Empty string when the score is 5.`,
    ``,
    `Then set "same_person" to false if a stranger shown the references and the candidate side by side would say these are two different people.`,
    ...(brief && Object.values(brief).some(Boolean)
      ? [
          ``,
          `## DID IT OBEY THE BRIEF`,
          ``,
          `This render was asked for specific things that have nothing to do with whose face it is:`,
          ``,
          ...(brief.framing ? [`CAMERA AND CROP: ${brief.framing}`] : []),
          ...(brief.expression ? [`EXPRESSION: ${brief.expression}`] : []),
          ...(brief.wardrobe ? [`WARDROBE: ${brief.wardrobe}`] : []),
          ``,
          `Set "brief_followed" to false if the candidate departs from any line above.`,
          ``,
          `Judge only those lines. A render can be a flawless likeness and still be the wrong shot, the wrong`,
          `expression or the wrong clothes. These are the mistakes to catch:`,
          `- A rear view delivered with the body facing the camera and only the head turned. If the brief says the`,
          `  camera is behind him, you must be looking at his back.`,
          `- A full-length asked for and delivered as a head-and-shoulders, or the reverse.`,
          `- An expression that is really a different one. A serious face and a closed-mouth half-smile are`,
          `  different briefs, and a faint smile delivered for "serious" is a failure, not a near miss.`,
          `- A garment drawn front-on over a body facing away. On a rear view you must see the BACK of the shirt:`,
          `  a shoulder yoke and an unbroken panel. A button placket, an open shirt front or a chest pocket on a`,
          `  back view means the model drew the front of the garment onto the back of the man. Fail it.`,
          `- Clothing that drifts between renders: sleeves rolled in one and long in another, a missing watch,`,
          `  a different shirt. The wardrobe line is exact.`,
          ``,
          `Judge the wardrobe ONLY on what this crop can show. The wardrobe line is written once for every`,
          `shot in the set, so it names trousers, a watch and shoes even for a head-and-shoulders frame. An item`,
          `the crop cannot reach is out of shot, not missing, and is NOT a failure. The framing decides what is`,
          `in frame; the wardrobe only decides what those items look like when they are.`,
          ``,
          `Do not let a good likeness excuse any of these, and do not let any of these change a likeness score above.`,
          `In "brief_note", name what you actually see and what was asked for. Empty string when it obeyed.`,
        ]
      : []),
    `Write "overall" as two or three sentences: what carries the likeness, and what breaks it.`,
    ``,
    `## THE ANCHORS`,
    ``,
    ...character.anchors.map(
      (a, i) => `${i + 1}. id="${a.id}" — ${a.label}\n   Examine: ${a.must}\n   Red flag: ${a.never}`,
    ),
  ].join("\n");
}

function buildSchema(withBrief) {
  return {
  type: "object",
  additionalProperties: false,
  properties: {
    anchors: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          id: { type: "string" },
          reference: { type: "string" },
          candidate: { type: "string" },
          score: { type: "integer" },
          correction: { type: "string" },
        },
        required: ["id", "reference", "candidate", "score", "correction"],
      },
    },
    overall: { type: "string" },
    same_person: { type: "boolean" },
    ...(withBrief ? { brief_followed: { type: "boolean" }, brief_note: { type: "string" } } : {}),
  },
  required: ["anchors", "overall", "same_person", ...(withBrief ? ["brief_followed", "brief_note"] : [])],
  };
}

async function callOpenRouter({ name, apiKey, instructions, images, withBrief }) {
  const content = [{ type: "text", text: instructions }];
  for (const img of images) {
    content.push({ type: "text", text: img.label });
    content.push({ type: "image_url", image_url: { url: `data:${img.mime};base64,${img.data}` } });
  }

  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
      "x-title": "character-studio",
    },
    body: JSON.stringify({
      model: name,
      temperature: 0,
      messages: [{ role: "user", content }],
      response_format: { type: "json_schema", json_schema: { name: "likeness", strict: true, schema: buildSchema(withBrief) } },
    }),
  });
  if (!res.ok) throw new Error(`OpenRouter ${res.status}: ${(await res.text()).slice(0, 600)}`);
  const json = await res.json();
  if (json.error) throw new Error(`OpenRouter: ${json.error.message}`);
  const text = json.choices?.[0]?.message?.content;
  if (!text) throw new Error(`OpenRouter returned no content: ${JSON.stringify(json).slice(0, 600)}`);
  return JSON.parse(stripFence(text));
}

/** Gemini wants its own OpenAPI-flavoured schema, and honours propertyOrdering. */
function geminiSchema(withBrief) {
  return {
    type: "OBJECT",
    properties: {
      anchors: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            id: { type: "STRING" },
            reference: { type: "STRING" },
            candidate: { type: "STRING" },
            score: { type: "INTEGER" },
            correction: { type: "STRING" },
          },
          required: ["id", "reference", "candidate", "score", "correction"],
          propertyOrdering: ["id", "reference", "candidate", "score", "correction"],
        },
      },
      overall: { type: "STRING" },
      same_person: { type: "BOOLEAN" },
      ...(withBrief ? { brief_followed: { type: "BOOLEAN" }, brief_note: { type: "STRING" } } : {}),
    },
    required: ["anchors", "overall", "same_person", ...(withBrief ? ["brief_followed", "brief_note"] : [])],
    propertyOrdering: ["anchors", "overall", "same_person", ...(withBrief ? ["brief_followed", "brief_note"] : [])],
  };
}

async function callGemini({ name, apiKey, instructions, images, withBrief }) {
  const parts = [{ text: instructions }];
  for (const img of images) {
    parts.push({ text: img.label });
    parts.push({ inline_data: { mime_type: img.mime, data: img.data } });
  }
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${name}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts }],
        generationConfig: {
          temperature: 0,
          responseMimeType: "application/json",
          responseSchema: geminiSchema(withBrief),
        },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 600)}`);
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.map((p) => p.text).join("") ?? "";
  if (!text) throw new Error(`Gemini returned no text: ${JSON.stringify(json).slice(0, 600)}`);
  return JSON.parse(stripFence(text));
}

const stripFence = (t) => t.trim().replace(/^```(?:json)?\s*/i, "").replace(/```$/, "").trim();

/** Weighted mean over judgeable anchors, plus a hard floor on every critical anchor. */
function score(character, report, withBrief = false) {
  const cfg = character.verification ?? {};
  const passScore = cfg.pass_score ?? 0.85;
  const criticalMin = cfg.critical_min ?? 4;
  const criticalWeight = cfg.critical_weight ?? 3;

  const byId = new Map(character.anchors.map((a) => [a.id, a]));
  const rows = (report.anchors ?? [])
    .filter((r) => byId.has(r.id))
    .map((r) => ({ ...r, label: byId.get(r.id).label, weight: byId.get(r.id).weight }));

  const missing = character.anchors.filter((a) => !rows.some((r) => r.id === a.id));
  if (missing.length) throw new Error(`Verifier skipped anchors: ${missing.map((m) => m.id).join(", ")}`);

  const judged = rows.filter((r) => r.score > 0);
  const total = judged.reduce((s, r) => s + r.weight * 5, 0);
  const got = judged.reduce((s, r) => s + r.weight * r.score, 0);
  const normalized = total ? got / total : 0;

  const failures = rows.filter((r) => r.weight >= criticalWeight && r.score > 0 && r.score < criticalMin);
  // Rank by how much a fix would gain: weight times the points missing.
  const ranked = rows
    .filter((r) => r.correction && r.score > 0 && r.score < 5)
    .sort((a, b) => b.weight * (5 - b.score) - a.weight * (5 - a.score));
  // A brief the render ignored is its own kind of failure, kept apart from the
  // likeness score on purpose. Camera, expression and wardrobe all say nothing
  // about whose face it is, so a render can be a flawless likeness of the right
  // man in the wrong shot, wearing the wrong clothes, pulling the wrong face.
  // Scoring the two together would let either one hide the other.
  //
  // It leads the corrections because only the first is fed back each round. A
  // sharper beard on a shot pointing the wrong way is a wasted attempt.
  const briefFailed = withBrief && report.brief_followed === false;
  const briefNote = briefFailed ? report.brief_note || "The render departs from the camera, expression or wardrobe the shot asked for." : "";

  const corrections = [...(briefFailed ? [briefNote] : []), ...ranked.map((r) => r.correction)];
  const weakest = briefFailed
    ? { id: "brief", label: "Camera, expression and wardrobe", correction: briefNote }
    : ranked.length
      ? { id: ranked[0].id, label: ranked[0].label, correction: ranked[0].correction }
      : null;

  return {
    score: Number(normalized.toFixed(3)),
    pass: normalized >= passScore && failures.length === 0 && report.same_person !== false && !briefFailed,
    same_person: report.same_person,
    overall: report.overall,
    anchors: rows,
    criticalFailures: [...failures.map((f) => f.id), ...(briefFailed ? ["brief"] : [])],
    brief_followed: withBrief ? report.brief_followed !== false : undefined,
    brief_note: briefNote,
    corrections,
    weakest,
  };
}
