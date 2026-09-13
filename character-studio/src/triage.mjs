import { readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { toInlineImage } from "./image.mjs";
import { parseModel } from "./verify.mjs";

/**
 * Classifies a folder of candidate photographs so a reference set can be chosen
 * on evidence rather than by opening 126 files by hand.
 *
 * Classification is a much easier job than the forensic likeness comparison the
 * verifier does, so a cheaper model is fine here. Images go in batches, because
 * one request per photo is slow and wasteful.
 */
export async function triage({ dir, model, apiKey, batchSize = 6, log = () => {} }) {
  const files = (await readdir(dir)).filter((f) => /\.(jpe?g|png|webp)$/i.test(f)).sort();
  if (!files.length) throw new Error(`No images in ${dir}`);

  const rows = [];
  for (let i = 0; i < files.length; i += batchSize) {
    const batch = files.slice(i, i + batchSize);
    log(`  ${i + 1}-${i + batch.length} of ${files.length}`);
    try {
      rows.push(...(await classifyBatch({ dir, batch, model, apiKey })));
    } catch (err) {
      log(`    batch failed: ${err.message}`);
      for (const f of batch) rows.push({ file: f, error: err.message, usable: false });
    }
  }

  await writeFile(path.join(dir, "triage.json"), JSON.stringify({ dir, model, rows }, null, 2));
  return rows;
}

const FIELDS = `
IDENTITY AND GROOMING
  beard            "clean", "stubble", "short-beard", "medium-beard", "full-beard", "goatee", "unclear"
  beard_mm         rough beard length in millimetres, integer, 0 when clean shaven
  beard_cheek_pct  percentage of the flat of the cheek actually covered by hair, integer 0-100
  beard_tone       "same-as-hair", "warmer-than-hair", "greying", "unclear"
  moustache        "connected", "separate", "none", "unclear"
  hair_length      "buzzed", "short", "medium", "long", "unclear"
  hair_style       "swept-back", "forward", "parted", "messy", "styled-up", "flat", "unclear"
  hair_volume      1 to 5, where 1 is flat to the skull and 5 is very voluminous
  hairline_visible true when the hairline and both temples are unobscured
  temple_recession "none", "slight", "clear", "strong", "unclear"
  glasses          "clear-round", "clear-other", "sunglasses", "none", "unclear"
  headwear         "none", "cap", "beanie", "helmet", "other"

MEASUREMENTS, estimated from this photo, integers
  forehead_pct     brow line to hairline, as a percentage of chin-to-hairline face height
  face_width_pct   cheekbone width as a percentage of chin-to-hairline face height
  shoulder_heads   shoulder width in head-widths, one decimal place, null when not visible
  face_size_pct    head height as a percentage of image height

FRAMING AND POSE
  framing          "head", "half", "full", "wide"
  angle            "frontal", "three-quarter", "profile", "back", "other"
  head_yaw         estimated head turn in degrees, 0 is facing camera, negative left, positive right
  head_pitch       estimated head tilt in degrees, 0 is level, negative down, positive up
  camera_height    "below", "eye-level", "above"
  eye_direction    "to-camera", "away", "closed", "hidden"
  expression       "neutral", "closed-smile", "open-smile", "talking", "serious", "squinting", "other"

PHOTOGRAPH
  light            "even", "soft-window", "hard-sun", "low-light", "backlit", "flash", "mixed"
  light_direction  "front", "left", "right", "above", "behind", "unclear"
  setting          "indoor", "outdoor", "studio", "vehicle", "unclear"
  background       one short phrase
  wardrobe         one short phrase on what he is wearing
  colour_cast      "neutral", "warm", "cool", "heavy-filter"
  sharpness        1 to 5, where 5 is a crisp in-focus face
  face_occluded    true when a hand, mask, object or heavy shadow hides part of the face

USABILITY
  usable           true only when exactly one adult man is the clear main subject, his face is in
                   focus, and the image is a real photograph rather than a screenshot or document
  subjects         how many people are visible
  ref_value        1 to 5, how useful this is as an identity reference photograph
  best_for         one short phrase, for example "profile reference" or "beard density"
  note             one short phrase on why it is or is not usable
`;

async function classifyBatch({ dir, batch, model, apiKey }) {
  const { provider, name } = parseModel(model);
  const instructions = [
    `Profile each attached photograph in detail. They are candidate reference photos of one person.`,
    `Return one object per photograph, in the same order, with every field below:`,
    FIELDS,
    `Judge only what you can see in that photograph. Do not guess who the person is and do not carry`,
    `an answer over from one photograph to the next. Estimate the measurements honestly; a rough`,
    `number is more useful than a refusal. Use null only when the feature is genuinely out of frame.`,
    `If a photo shows a group, a place, a screenshot or a document, set usable to false and say why.`,
    `Return JSON: {"rows": [ ... ]} with one row per photograph, in order.`,
  ].join("\n");

  const images = [];
  for (const f of batch) images.push({ label: f, ...(await toInlineImage(path.join(dir, f), { maxEdge: 1024 })) });

  const raw =
    provider === "gemini"
      ? await callGemini({ name, apiKey, instructions, images })
      : await callOpenRouter({ name, apiKey, instructions, images });

  const rows = raw.rows ?? [];
  return batch.map((f, i) => ({ ...(rows[i] ?? { usable: false, note: "no classification returned" }), file: f }));
}

async function callOpenRouter({ name, apiKey, instructions, images }) {
  const content = [{ type: "text", text: instructions }];
  for (const img of images) {
    content.push({ type: "text", text: `PHOTO: ${img.label}` });
    content.push({ type: "image_url", image_url: { url: `data:${img.mime};base64,${img.data}` } });
  }
  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json", "x-title": "character-studio" },
    body: JSON.stringify({
      model: name,
      temperature: 0,
      messages: [{ role: "user", content }],
      response_format: { type: "json_object" },
    }),
  });
  if (!res.ok) throw new Error(`OpenRouter ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const json = await res.json();
  return JSON.parse(strip(json.choices?.[0]?.message?.content ?? "{}"));
}

async function callGemini({ name, apiKey, instructions, images }) {
  const parts = [{ text: instructions }];
  for (const img of images) {
    parts.push({ text: `PHOTO: ${img.label}` });
    parts.push({ inline_data: { mime_type: img.mime, data: img.data } });
  }
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${name}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts }],
        generationConfig: { temperature: 0, responseMimeType: "application/json" },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.map((p) => p.text).join("") ?? "{}";
  return JSON.parse(strip(text));
}

const strip = (t) => t.trim().replace(/^```(?:json)?\s*/i, "").replace(/```$/, "").trim();

/**
 * Picks a spread of references from triaged rows.
 *
 * A reference set wants coverage, not the twenty best headshots. One strong
 * photo per angle, per framing and per beard state teaches the model more than
 * twenty near-duplicates of the same pose.
 */
export function chooseReferences(rows, { perSlot = 2 } = {}) {
  const usable = rows.filter((r) => r.usable && r.subjects === 1 && (r.sharpness ?? 0) >= 3);
  const score = (r) =>
    (r.ref_value ?? 0) * 20 +
    (r.sharpness ?? 0) * 10 +
    (r.face_size_pct ?? 0) / 5 +
    (r.hairline_visible ? 8 : 0) +
    (r.face_occluded ? -20 : 0) +
    (r.light === "even" || r.light === "soft-window" ? 5 : 0);

  const slots = new Map();
  for (const r of usable) {
    const key = `${r.framing}/${r.angle}/${r.beard}`;
    const list = slots.get(key) ?? [];
    list.push(r);
    slots.set(key, list);
  }

  const chosen = [];
  for (const [key, list] of [...slots.entries()].sort()) {
    list.sort((a, b) => score(b) - score(a));
    for (const r of list.slice(0, perSlot)) chosen.push({ ...r, slot: key });
  }
  return { usable: usable.length, total: rows.length, slots: slots.size, chosen };
}
