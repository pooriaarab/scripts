// Smallest real Framer-plugin wiring: open the plugin window, read the current canvas
// selection image, upload its bytes to your API, create the downstream action.
// Swap `postToApi` for your product's SDK or public REST call.

import { framer, type ImageAsset } from "framer-plugin";

// 1. Size the window BEFORE rendering anything, or you get a blank panel.
void framer.showUI({ position: "top right", width: 340, height: 480, resizable: true });

async function shareCurrentSelection(apiKey: string, apiBase: string) {
  // 2. The selection is SDK-read, never DOM-read. This is async; null when nothing
  //    usable is selected. Use framer.subscribeToImage(cb) to track re-selection.
  const asset: ImageAsset | null = await framer.getImage();
  if (!asset) throw new Error("Select an image on the canvas first");

  const { bytes, mimeType } = await asset.getData(); // also async
  const form = new FormData();
  form.append("file", new Blob([bytes as BlobPart], { type: mimeType }), "framer-selection.png");
  const media = await postToApi(apiBase, "/media", apiKey, form);

  await postToApi(apiBase, "/posts", apiKey, {
    content: "Shared from Framer",
    mediaIds: [media.id],
  });
}

// 3. The API key persists per PROJECT (not globally) — read on load, gate the UI.
async function loadStoredKey(): Promise<string | null> {
  return framer.getPluginData("apiKey"); // async; framer.setPluginData("apiKey", key) to save
}

async function postToApi(base: string, path: string, key: string, body: unknown) {
  const isForm = body instanceof FormData;
  const res = await fetch(base + path, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, ...(isForm ? {} : { "Content-Type": "application/json" }) },
    body: isForm ? (body as FormData) : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`); // surface, don't swallow
  return res.json();
}

export { shareCurrentSelection, loadStoredKey };
