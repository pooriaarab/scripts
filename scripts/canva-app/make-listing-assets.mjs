#!/usr/bin/env node
/**
 * Render the two Canva App Marketplace listing rasters from SVG sources.
 *
 *   node make-listing-assets.mjs <dir> [background]
 *
 * Expects <dir>/icon-512.svg and <dir>/featured-2400x1800.svg, writes the PNGs
 * beside them.
 *
 * Canva rejects an icon that is not exactly 512x512, or that carries an alpha
 * channel or rounded corners. `sips` cannot strip alpha and a JPEG round-trip
 * adds visible artifacts to flat brand colour, so this uses sharp's flatten().
 * Render the icon from a SQUARE, UNCLIPPED source -- the rounded-corner variant
 * most brand kits ship as the app/PWA icon is exactly what gets rejected.
 */
import { statSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const [dir = "./listing", background = "#ffffff"] = process.argv.slice(2);

// sharp is resolved from the host project rather than vendored here.
let sharp;
try {
  sharp = createRequire(join(process.cwd(), "package.json"))("sharp");
} catch {
  console.error("sharp not found. Install it in this project: npm i -D sharp");
  process.exit(1);
}

const TARGETS = [
  { name: "icon-512", width: 512, height: 512, density: 600 },
  { name: "featured-2400x1800", width: 2400, height: 1800, density: 200 },
];

let failed = false;
for (const { name, width, height, density } of TARGETS) {
  const src = join(dir, `${name}.svg`);
  const out = join(dir, `${name}.png`);
  try {
    await sharp(src, { density })
      .resize(width, height, { fit: "fill" })
      .flatten({ background }) // the alpha channel Canva rejects
      .png({ compressionLevel: 9 })
      .toFile(out);
    const meta = await sharp(out).metadata();
    const kb = Math.round(statSync(out).size / 1024);
    const ok = meta.width === width && meta.height === height && !meta.hasAlpha;
    if (!ok) failed = true;
    console.log(
      `${ok ? "ok  " : "BAD "} ${out}  ${meta.width}x${meta.height}  ` +
        `channels=${meta.channels} alpha=${!!meta.hasAlpha}  ${kb}KB`,
    );
    if (kb > 5 * 1024) {
      failed = true;
      console.log(`BAD  ${out} exceeds Canva's 5MB limit`);
    }
  } catch (cause) {
    failed = true;
    console.error(`BAD  ${src}: ${cause instanceof Error ? cause.message : cause}`);
  }
}
process.exit(failed ? 1 : 0);
