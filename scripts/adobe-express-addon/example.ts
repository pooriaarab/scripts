// Smallest real Adobe Express add-on wiring: export the current design, hand the blob
// to your API. Runs in the add-on iframe. Swap postToApi for your product's SDK/REST.
// The external origin MUST be in the add-on manifest allow-list or the fetch fails.

import addOnUISdk from "https://express.adobe.com/static/add-on-sdk/sdk.js";

async function shareCurrentDesign(apiKey: string, apiBase: string) {
  await addOnUISdk.ready;

  // createRenditions is ASYNC and can return multiple renditions (multi-page docs).
  const renditions = await addOnUISdk.app.document.createRenditions({
    range: "currentPage",
    format: "image/png" as never,
  });

  for (const r of renditions) {
    const blob = (r as { blob: Blob }).blob;

    const form = new FormData();
    form.append("file", blob, "design.png");
    const media = await postToApi(apiBase, "/media", apiKey, form);

    await postToApi(apiBase, "/posts", apiKey, {
      content: "Shared from Adobe Express",
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
