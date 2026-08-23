// Smallest real Canva-app wiring: export the current design, then hand the blob to
// your API. Runs inside the Canva iframe (import { requestExport } from "@canva/design").
// Swap `postToApi` for your product's SDK or REST call.

import { requestExport } from "@canva/design";

async function shareCurrentDesign(apiKey: string, apiBase: string) {
  // Export is ASYNC and opens Canva's own export UI; the user can cancel it, and a
  // design can export as multiple blobs (multi-page designs).
  const response = await requestExport({ acceptedFileTypes: ["png"] });
  if (response.status !== "completed") return; // user cancelled the export dialog

  for (const b of response.exportBlobs) {
    const blob = await (await fetch(b.url)).blob(); // Canva returns a URL, not an in-memory Blob

    // External origin MUST be allow-listed in the Developer Portal or this fails silently.
    const form = new FormData();
    form.append("file", blob, "design.png");
    const media = await postToApi(apiBase, "/media", apiKey, form);

    await postToApi(apiBase, "/posts", apiKey, {
      content: "Shared from Canva",
      mediaIds: [media.id],
    });
  }
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

export { shareCurrentDesign };
