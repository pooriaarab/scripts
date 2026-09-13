import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

/** Used when a pack omits verification.model. Prefixed, so the provider is never guessed. */
export const DEFAULT_VERIFIER = "gemini://gemini-3.1-pro-preview";

/**
 * A character pack is a directory holding character.json, shots.json and a refs/
 * directory of real photographs. Everything the studio knows about a person comes
 * from one of those three, so a second person only needs a second directory.
 */
export async function loadPack(dir) {
  const character = JSON.parse(await readFile(path.join(dir, "character.json"), "utf8"));
  const shotsPath = path.join(dir, "shots.json");
  const shots = existsSync(shotsPath)
    ? JSON.parse(await readFile(shotsPath, "utf8"))
    : { defaults: {}, shots: [] };

  const byFile = new Map(character.references.map((r) => [r.file, r]));
  for (const ref of character.references) {
    if (!ref.url) throw new Error(`Reference ${ref.file} has no CDN url. Run: character-studio refs ${dir}`);
  }

  return { dir, character, shots, refUrl: (file) => resolveRef(byFile, file) };
}

function resolveRef(byFile, file) {
  const ref = byFile.get(file);
  if (!ref) throw new Error(`Unknown reference "${file}". Add it to character.json references.`);
  return ref.url;
}

/**
 * Local path for a reference, or its CDN url when the file is not on disk.
 * Reference photographs are gitignored, so a fresh clone verifies against the
 * same images over the network instead of failing.
 */
export function refSource(pack, file) {
  const local = path.join(pack.dir, "refs", file);
  return existsSync(local) ? local : pack.refUrl(file);
}

/**
 * Applies a shot's variant to the character.
 *
 * Some traits vary shot to shot while the anchor around them holds. Beard shape
 * is the worked example: length and outline change, sparse cheeks do not. A
 * variant overrides only the fields it names on the anchors it names.
 */
export function applyVariant(character, variantId) {
  if (!variantId) return character;
  const variant = character.variants?.[variantId];
  if (!variant) throw new Error(`Unknown variant "${variantId}". Declared: ${Object.keys(character.variants ?? {}).join(", ") || "none"}`);
  return {
    ...character,
    anchors: character.anchors.map((a) => (variant.anchors?.[a.id] ? { ...a, ...variant.anchors[a.id] } : a)),
  };
}

export function findShot(pack, id) {
  const shot = pack.shots.shots.find((s) => s.id === id);
  if (!shot) throw new Error(`Unknown shot "${id}".`);
  return { ...pack.shots.defaults, ...shot };
}

export function allShots(pack) {
  return pack.shots.shots.map((s) => ({ ...pack.shots.defaults, ...s }));
}

/**
 * Anchors a given shot can actually show.
 *
 * An anchor may declare `requires: "body"`. A waist-up shot cannot show height
 * or limb length, so scoring that anchor there produces a failure no prompt can
 * fix. Shots declare `scope` as head, half or full.
 */
export function anchorsForScope(character, scope = "full") {
  if (scope === "full") return character.anchors;
  return character.anchors.filter((a) => a.requires !== "body");
}

/** Anchors at or above the pack's critical weight must each clear critical_min on their own. */
export function criticalAnchors(character) {
  const w = character.verification?.critical_weight ?? 3;
  return character.anchors.filter((a) => a.weight >= w);
}
