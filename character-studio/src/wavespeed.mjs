import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const run = promisify(execFile);

/** Shells the wavespeed CLI. Inputs go through a temp JSON file so prompts and URL arrays survive intact. */
export async function wavespeedRun(model, input, { timeoutMs = 600_000 } = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), "cstudio-"));
  const file = path.join(dir, "input.json");
  try {
    await writeFile(file, JSON.stringify(input));
    const { stdout } = await run("wavespeed", ["run", model, "--input-file", file, "--json"], {
      timeout: timeoutMs,
      maxBuffer: 64 * 1024 * 1024,
      env: { ...process.env, PATH: `${process.env.PATH}:/opt/homebrew/bin:/usr/local/bin` },
    });
    const result = JSON.parse(stdout);
    const urls = extractUrls(result);
    if (!urls.length) throw new Error(`No output image in wavespeed response: ${stdout.slice(0, 500)}`);
    return { urls, raw: result };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/** The CLI has moved the output key between versions, so look for the first array of image URLs. */
function extractUrls(obj) {
  const found = [];
  const walk = (node) => {
    if (!node) return;
    if (typeof node === "string") {
      if (/^https?:\/\/.+\.(png|jpe?g|webp)(\?|$)/i.test(node)) found.push(node);
      return;
    }
    if (Array.isArray(node)) return node.forEach(walk);
    if (typeof node === "object") return Object.values(node).forEach(walk);
  };
  walk(obj.outputs ?? obj.output ?? obj.data ?? obj);
  return [...new Set(found)];
}

export async function wavespeedUpload(files) {
  // The CLI prints its progress lines, and the result urls with them, on
  // stderr. Reading only stdout parsed zero urls from a successful upload.
  const { stdout, stderr } = await run("wavespeed", ["upload", ...files], {
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, PATH: `${process.env.PATH}:/opt/homebrew/bin:/usr/local/bin` },
  });
  const urls = [...`${stdout}\n${stderr}`.matchAll(/→\s+(https?:\/\/\S+)/g)].map((m) => m[1]);
  if (urls.length !== files.length) {
    throw new Error(`Uploaded ${files.length} files but parsed ${urls.length} urls from:\n${stdout}`);
  }
  return Object.fromEntries(files.map((f, i) => [path.basename(f), urls[i]]));
}

export async function download(url, dest) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Download failed ${res.status} for ${url}`);
  await writeFile(dest, Buffer.from(await res.arrayBuffer()));
  return dest;
}
