import { anchorsForShot } from "./pack.mjs";

/**
 * Composes the prompt sent to the image model.
 *
 * The hard lesson behind this shape: a long prose description of a face makes the
 * model GENERATE a face from the words and ignore the reference photographs. The
 * first version of this file emitted every anchor's full MUST and NEVER text and
 * produced a Northern European stranger from four photographs of a Persian man.
 *
 * So generation and verification now read different fields. Generation gets the
 * short `check` line per anchor, framed as a checklist to compare the output
 * against. Verification gets the full `must` and `never` text. The photographs
 * stay the source of the likeness; the words only catch drift.
 */
export function buildPrompt({ character, shot, corrections = [] }) {
  // The shot's own expression wins over the expression anchor. The anchor
  // describes his habitual face — "closed-mouth asymmetric half-smile" — which
  // is the right thing to hold in a portrait and flatly wrong in a panel asking
  // for neutral or serious. Leaving both in the prompt made the model split the
  // difference, and every expression panel came back as the same faint smile.
  const anchors = [...anchorsForShot(character, shot)].sort((a, b) => b.weight - a.weight);
  const criticalWeight = character.verification?.critical_weight ?? 3;
  const out = [];

  out.push(
    `The attached photographs are all of ONE REAL MAN. Image 1 is the primary face reference.`,
    ``,
    `Produce a new photograph of that same man. Copy his likeness directly from the attached photographs: the same face, the same head and skull shape, the same hairline, the same beard, the same skin tone and ethnicity, the same build.`,
    ``,
    `This is a photo edit of a real individual. Do NOT design a new character. Do NOT substitute a generic handsome face. Do NOT change his ethnicity. A viewer who knows this man must recognise him instantly.`,
    ``,
    `Change only the scene, the pose, the wardrobe and the light, as specified here:`,
    ``,
    `Framing: ${shot.framing}`,
    // The wardrobe is written once for the whole pack, so it names chinos, a
    // watch and shoes. On a head-and-shoulders panel that contradicts the crop,
    // and the model resolved the contradiction by pulling the camera back and
    // rendering the whole body. Saying which instruction wins costs one line.
    `The framing is the final word on what is in frame. Wardrobe items the crop cannot reach — shoes, trousers, a watch — are simply out of shot. Do NOT widen the shot to include them.`,
    `Scene: ${shot.scene}`,
    `Wardrobe: ${shot.wardrobe}`,
    `Expression: ${shot.expression}`,
    `Light: ${shot.light}`,
  );
  if (shot.extra) out.push(`Also: ${shot.extra}`);
  out.push(``);

  out.push(
    `Photographic style: ${character.render.look}`,
    `Avoid: ${character.render.never}`,
    ``,
    `## CHECK YOUR OUTPUT AGAINST THE PHOTOGRAPHS`,
    `Before you finish, compare the face you have drawn with the attached photographs. These traits are the ones that drift. Each one must match the photographs:`,
    ``,
  );

  for (const a of anchors) out.push(`- ${a.check}${a.weight >= criticalWeight ? "  (critical)" : ""}`);
  out.push(``);

  if (corrections.length) {
    out.push(
      `## FIX THESE FAULTS FROM THE PREVIOUS ATTEMPT`,
      `A previous render of this shot was rejected against the photographs. Fix every line below.`,
      ``,
      ...corrections.map((c) => `- ${c}`),
      ``,
    );
  }

  out.push(
    `If the man you have drawn does not look like the man in the attached photographs, draw the face again from the photographs.`,
  );

  return out.join("\n");
}

/**
 * The model-sheet prompt. Same image-first framing, different job: one landscape
 * production board rather than one photograph.
 */
export function buildSheetPrompt({ character, board, corrections = [] }) {
  const anchors = [...character.anchors].sort((a, b) => b.weight - a.weight);
  const criticalWeight = character.verification?.critical_weight ?? 3;
  const out = [];

  out.push(
    `The attached photographs are all of ONE REAL MAN. Image 1 is the primary face reference.`,
    ``,
    `Create a premium professional character design reference sheet, a production model sheet, of that same man.`,
    ``,
    `Copy his likeness directly from the attached photographs into every panel: the same face, the same head and skull shape, the same hairline, the same beard, the same skin tone and ethnicity, the same body proportions, the same age. Do not redesign, beautify, simplify, age, de-age or reinterpret him. Do not substitute a generic face. Do not change his ethnicity.`,
    ``,
    `## PAGE FORMAT`,
    `One studio-grade character reference board, landscape 16:9, on a clean neutral off-white studio background. Refined editorial production-board layout, clear hierarchy, generous spacing, subtle technical guide lines, restrained typographic labels, no decorative clutter.`,
    ``,
    board,
    ``,
    `## DESIGN CONTINUITY`,
    `Treat the whole page as one canonical source of truth. Every panel shows the same man with identical facial identity, identical body proportions, identical hairstyle, identical wardrobe, identical accessory placement and one consistent colour palette. No accidental wardrobe changes, no missing or duplicated accessories, no drifting facial features, no inconsistent hairstyles.`,
    ``,
    `## CHECK EVERY PANEL AGAINST THE PHOTOGRAPHS`,
    `These traits are the ones that drift. Each must match the attached photographs in every panel:`,
    ``,
    ...anchors.map((a) => `- ${a.check}${a.weight >= criticalWeight ? "  (critical)" : ""}`),
    ``,
    `## RENDER FINISH — PHOTOGRAPHIC, NOT ILLUSTRATED`,
    `Every panel is PHOTOREALISTIC. Render the man as photographs of a real person: real skin with pores and texture, real hair with individual strands, real fabric weave, real specular highlights, true photographic depth and tonality.`,
    `This is NOT an illustration. No vector art, no cel shading, no flat colour fills, no outlines or line art, no comic or anime style, no 3D cartoon render, no digital painting, no airbrushed CGI look.`,
    `Only the layout furniture may be graphic: the panel frames, the alignment guides, the labels and the colour-swatch chips.`,
    ``,
    `## WARDROBE FOR THE SHEET`,
    `Dress him the same way in every panel: ${character.sheetWardrobe ?? character.wardrobe.default}`,
    ``,
    `## TEXT ON THE PAGE`,
    `Title the board exactly: ${character.name.toUpperCase()} — CHARACTER REFERENCE`,
    `Use only the section headings given above and the short labels named in them. Do not invent any other name, caption, paragraph, signature, watermark or logo. Spell every word correctly.`,
    ``,
    `## VISUAL DIRECTION`,
    `High-end professional character design presentation. Studio production reference quality. Precise construction, controlled neutral lighting built for design inspection rather than drama, excellent anatomical consistency, crisp readable detail.`,
    ``,
    `## NEGATIVE CONSTRAINTS`,
    `No identity drift, no changing face between panels, no changing hairstyle, no wardrobe variation, no missing accessories, no duplicated accessories, no extra limbs, no malformed hands, no distorted anatomy, no random props, no cinematic scenery, no heavy effects, no clutter, no watermark, no logo, no cropped views.`,
  );

  if (corrections.length) {
    out.push(
      ``,
      `## FIX THESE FAULTS FROM THE PREVIOUS ATTEMPT`,
      `A previous version of this sheet was rejected against the photographs. Fix every line below in every panel.`,
      ``,
      ...corrections.map((c) => `- ${c}`),
    );
  }

  return out.join("\n");
}
