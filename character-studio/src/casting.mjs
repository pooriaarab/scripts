import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { renderShot } from "./pipeline.mjs";
import { wavespeedUpload } from "./wavespeed.mjs";

/**
 * The casting sheet: four plain frames of one person in a 2x2 grid.
 *
 * It exists to carry identity into later renders. A scene written from words
 * alone gives a different face every time, because the words describe a type of
 * man rather than this man. So the approved sheet goes into a later shot's
 * reference images and the likeness travels as a picture instead of as prose.
 * One sheet, reused, is also cheaper than re-describing the face in every shot.
 *
 * WARNING — only the plain four-frame card may be fed back as a reference. The
 * `sheet` and `compose` commands build the other kind of board: nine or more
 * panels with turnarounds, an expression grid, palette strips, labels and
 * callout lines. That board is made for artists to read. Fed back into a
 * photoreal edit model it degrades identity transfer, because the model
 * reproduces the board layout instead of the person. Expressions leak into the
 * scene, palette strips arrive as props, and callout lines sharpen into
 * artefacts. Four frames, one grey background, no text. Never register a
 * character-sheet render as the casting sheet.
 *
 * The grid is described in the shot's own `framing` and `scene` fields rather
 * than in a prompt builder of its own. That keeps the sheet inside renderShot,
 * so it is verified against the real photographs and retried against its own
 * faults like any other render. A reference image nobody scored is a reference
 * image that can carry the wrong face into every shot that uses it.
 */

/** Output basename. A run writes <label>.jpg and <label>.report.json. */
export const CASTING_LABEL = "casting-sheet";

/** Last resort only. A pack with a shots.json takes the model its shots use. */
const FALLBACK_MODEL = "google/nano-banana-pro/edit";

/**
 * The four frames a casting director asks for, as one shot spec.
 *
 * Wardrobe, hair and light are pinned across all four frames on purpose. A
 * frame that drifts teaches the edit model that drift is allowed, and the shots
 * that reference the sheet inherit that permission.
 */
export function buildCastingShot({ character, label = CASTING_LABEL, model, resolution, variant, refs }) {
  const wardrobe = character.sheetWardrobe ?? character.wardrobe.default;
  return {
    id: label,
    group: "casting",
    model: model ?? FALLBACK_MODEL,
    aspect_ratio: "1:1",
    // 2k over the sheet's 4k. The card is read by a model, not by a person, and
    // a square 2k render still gives each of the four frames about 1k.
    resolution: resolution ?? "2k",
    output_format: "jpeg",
    // A full body frame is present, so the body anchors are scorable here.
    scope: "full",
    variant,
    refs,
    framing:
      "One square image holding four separate photographs of the same man in a 2x2 grid. " +
      "Top left: front view, head and shoulders, square to camera. " +
      "Top right: three-quarter view, head turned about 45 degrees to his left, head and shoulders. " +
      "Bottom left: strict side profile, a full 90 degrees, one ear to camera, head and shoulders. " +
      "Bottom right: full body, standing straight, arms relaxed at his sides, head to shoes inside the frame. " +
      "The four frames meet edge to edge. No borders, no gutters, no drop shadows.",
    scene:
      "A seamless mid-grey studio background, the same flat neutral grey behind him in all four frames. " +
      "Nothing else in frame: no props, no furniture, no floor line, no visible backdrop seam, no cast shadow on the wall.",
    wardrobe: `${wardrobe} The same clothing, worn the same way, and the same hair in all four frames.`,
    expression:
      "Neutral in all four frames. Mouth closed, jaw relaxed, no smile. " +
      "Eyes to the lens in the front and full body frames, eyes level and straight ahead in the three-quarter and profile frames.",
    light:
      "One large soft key at about 45 degrees from camera left, with a gentle fill on the right. " +
      "The same light, the same direction and the same strength in all four frames, as if the four photographs were taken minutes apart without moving a lamp.",
    extra:
      "This is a casting card, not a design board. " +
      "No text, no names, no labels, no captions, no arrows, no measurement lines, no colour swatches, no logos anywhere in the image.",
  };
}

/** Renders the casting sheet through the ordinary verify-and-retry loop. */
export async function renderCasting({ pack, outDir, apiKey, label, model, resolution, variant, log }) {
  const defaults = pack.shots.defaults ?? {};
  const shot = buildCastingShot({
    character: pack.character,
    label,
    model: model ?? defaults.model,
    resolution: resolution ?? defaults.resolution,
    variant,
    refs: defaults.refs,
  });
  return renderShot({ pack, shot, outDir, apiKey, log });
}

/**
 * Uploads the approved sheet and records it in character.json.
 *
 * character.json is re-read from disk rather than serialised out of
 * pack.character. The loaded pack carries command-line overrides — a
 * --verifier writes itself into pack.character.verification.model — and
 * writing that object back would bake one run's flags into the pack.
 */
export async function registerCastingSheet({ pack, file, score }) {
  const urls = await wavespeedUpload([file]);
  const charFile = path.join(pack.dir, "character.json");
  const character = JSON.parse(await readFile(charFile, "utf8"));
  const sheet = {
    file: path.basename(file),
    url: urls[path.basename(file)],
    score,
    date: new Date().toISOString().slice(0, 10),
  };
  character.castingSheet = sheet;
  await writeFile(charFile, `${JSON.stringify(character, null, 2)}\n`);
  // The in-memory pack outlives this call, so a shot rendered later in the same
  // run finds the sheet instead of the state the pack loaded with.
  pack.character.castingSheet = sheet;
  return sheet;
}
