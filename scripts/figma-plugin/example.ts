// Smallest real Figma-plugin wiring (sandbox side, code.ts): export the selected frame,
// hand-roll the multipart body (no FormData in the sandbox), and call your API.
// Swap API_BASE/paths for your product's SDK or REST call; list every origin in manifest.json networkAccess.allowedDomains.

const API_BASE = "https://api.example.com/v1";

figma.showUI(__html__, { width: 420, height: 600, themeColors: true });

async function exportSelectionAndPost(apiKey: string) {
  const node = figma.currentPage.selection[0];
  if (!node) throw new Error("Select a frame or layer first.");

  // Export is async and returns raw bytes (Uint8Array), not a Blob.
  const png = await node.exportAsync({ format: "PNG", constraint: { type: "SCALE", value: 2 } });

  // The sandbox has no DOM: build multipart/form-data manually.
  const boundary = `figma${Date.now().toString(36)}`;
  const enc = new TextEncoder();
  const head = enc.encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="frame.png"\r\nContent-Type: image/png\r\n\r\n`,
  );
  const tail = enc.encode(`\r\n--${boundary}--\r\n`);
  const fileBody = new Uint8Array(head.length + png.length + tail.length);
  fileBody.set(head, 0);
  fileBody.set(png, head.length);
  fileBody.set(tail, head.length + png.length);

  const media = await postToApi(apiKey, "/media", fileBody, `multipart/form-data; boundary=${boundary}`);
  if (!media?.id) throw new Error("media upload missing id");
  await postToApi(
    apiKey,
    "/posts",
    JSON.stringify({ content: "Shared from Figma", mediaIds: [media.id] }),
    "application/json",
  );
}

async function postToApi(apiKey: string, path: string, body: BodyInit, contentType: string) {
  const res = await fetch(`${API_BASE}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": contentType },
    body,
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`); // surface, don't swallow
  return res.json();
}

// The UI iframe only sends intents: parent.postMessage({ pluginMessage: { type: "share" } }, "*").
// The sandbox owns the API key (figma.clientStorage) and every fetch.
figma.ui.onmessage = async (msg) => {
  if (msg.type === "share") {
    const apiKey = await figma.clientStorage.getAsync("apiKey");
    try {
      if (typeof apiKey !== "string" || !apiKey) throw new Error("Add your API key in Settings first.");
      await exportSelectionAndPost(apiKey);
      figma.ui.postMessage({ type: "share-result", ok: true });
      figma.notify("Shared");
    } catch (e) {
      figma.ui.postMessage({ type: "share-result", ok: false, error: e instanceof Error ? e.message : String(e) });
    }
  }
  if (msg.type === "close") figma.closePlugin();
};
