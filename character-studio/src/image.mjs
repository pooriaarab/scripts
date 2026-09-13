import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const run = promisify(execFile);

/**
 * Downscales an image before it goes to a vision model.
 *
 * Full-resolution references push a six-image request past several providers'
 * request-size limits, which surfaces only as an opaque "fetch failed". 1200px
 * on the long edge is well above what any of these models resolve internally,
 * so nothing that matters for a likeness judgement is lost.
 */
export async function toInlineImage(src, { maxEdge = Number(process.env.CS_MAX_EDGE) || 1200, quality = 82 } = {}) {
  const buf = /^https?:\/\//.test(src) ? await fetchBuffer(src) : await readFile(src);
  const resized = await resize(buf, maxEdge, quality);
  return { mime: "image/jpeg", data: resized.toString("base64") };
}

async function fetchBuffer(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Could not fetch ${url}: ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

let backend;

async function resize(buf, maxEdge, quality) {
  backend ??= await detect();
  if (backend === "none") return buf;

  const dir = await mkdtemp(path.join(tmpdir(), "cstudio-img-"));
  const input = path.join(dir, "in");
  const output = path.join(dir, "out.jpg");
  try {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(input, buf);
    if (backend === "sips") {
      await run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", String(quality),
        "-Z", String(maxEdge), input, "--out", output]);
    } else {
      await run("ffmpeg", ["-y", "-loglevel", "error", "-i", input,
        "-vf", `scale='min(${maxEdge},iw)':'min(${maxEdge},ih)':force_original_aspect_ratio=decrease`,
        "-q:v", "4", output]);
    }
    return await readFile(output);
  } catch {
    return buf;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function detect() {
  for (const [cmd, args, name] of [
    ["sips", ["--version"], "sips"],
    ["ffmpeg", ["-version"], "ffmpeg"],
  ]) {
    try {
      await run(cmd, args, { env: { ...process.env, PATH: `${process.env.PATH}:/opt/homebrew/bin:/usr/local/bin:/usr/bin` } });
      return name;
    } catch {}
  }
  return "none";
}
