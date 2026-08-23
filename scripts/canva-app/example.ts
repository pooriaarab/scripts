// Smallest real Canva-app wiring: export the current design, then hand the blob to
// your API. Runs inside the Canva iframe (import { addOnUISdk } from "@canva/app-sdk").
// Swap `postToApi` for your product's SDK or REST call.

import { addOnUISdk } from "@canva/app-ui-kit"; // or the current @canva SDK entrypoint

async function shareCurrentDesign(apiKey: string, apiBase: string) {
  // Design export is ASYNC and can return multiple renditions (multi-page designs).
  const { renditions } = await addOnUISdk.app.document.createRenditions({
    range: "currentPage",
    format: "png",
  });

  for (const r of renditions) {
    const blob = await (await fetch(r.blobUrl)).blob(); // r.blobUrl is same-origin, allowed

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
