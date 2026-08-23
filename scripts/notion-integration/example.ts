// Smallest real Notion-integration wiring: OAuth exchange, query a database for
// rows at a status, hand each row to your API, write the result back onto the row.

import { Client } from "@notionhq/client";

// --- OAuth: one access token per workspace install (no refresh token — store it) ---
export async function exchangeCode(
  clientId: string,
  clientSecret: string,
  redirectUri: string,
  code: string,
) {
  return new Client().oauth.token({
    client_id: clientId,
    client_secret: clientSecret,
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri, // must byte-match a URI registered on the integration
  });
}

const plain = (parts?: Array<{ plain_text: string }>) =>
  (parts ?? []).map((p) => p.plain_text).join("").trim();

// --- status vs select: detect once; filter AND write-back syntax depend on it ---
async function statusType(notion: Client, databaseId: string, prop: string) {
  const db = await notion.databases.retrieve({ database_id: databaseId });
  const type = (db.properties as Record<string, { type: string }>)[prop]?.type;
  if (!type) throw new Error(`No "${prop}" property — or the database is not granted to the integration.`);
  if (type !== "status" && type !== "select") {
    throw new Error(`"${prop}" must be a Status or Select property (found: ${type}).`);
  }
  return type;
}

export async function syncOnce(token: string, databaseId: string, apiBase: string, apiKey: string) {
  const notion = new Client({ auth: token });
  const kind = await statusType(notion, databaseId, "Status");

  const filter =
    kind === "status"
      ? { property: "Status", status: { equals: "Ready" } }
      : { property: "Status", select: { equals: "Ready" } };
  // Paginate: a single page tops out at 100 rows, so >100 "Ready" rows would
  // otherwise leave every row past the first page unsynced.
  const pages: Array<{ id: string; properties: Record<string, any> }> = [];
  let cursor: string | undefined;
  do {
    const res = await notion.databases.query({
      database_id: databaseId,
      filter,
      page_size: 100,
      start_cursor: cursor,
    });
    pages.push(...(res.results as Array<{ id: string; properties: Record<string, any> }>));
    cursor = res.has_more ? (res.next_cursor ?? undefined) : undefined;
  } while (cursor);

  for (const page of pages) {
    const p = (page as { properties: Record<string, any> }).properties;
    if (plain(p["Post ID"]?.rich_text)) continue; // already synced — re-runs are safe
    const row = {
      title: plain(p.Name?.title),
      body: plain(p.Body?.rich_text),
      date: p.Date?.date?.start ?? null,
      platforms: (p.Platforms?.multi_select ?? []).map((o: { name: string }) => o.name),
    };

    let post: { id?: unknown } | undefined;
    try {
      post = await postToApi(apiBase, "/posts", apiKey, {
        title: row.title,
        content: row.body || row.title,
        scheduledAt: row.date,
        platforms: row.platforms,
      });
      // A 2xx with no usable id means we can't tell whether a remote resource was
      // created; don't persist "undefined" as the Post ID or the continue guard
      // above would skip this row forever with no real remote link.
      if (!post?.id) throw new Error("API response missing id");

      // Write the idempotency marker (Post ID) first and on its own: if the Status
      // write below fails (e.g. the "Done" option doesn't exist yet), the row still
      // shows a Post ID and the `continue` guard above stops the next run from
      // re-posting and creating a duplicate.
      await notion.pages.update({
        page_id: page.id,
        properties: {
          "Post ID": { rich_text: [{ type: "text", text: { content: String(post.id) } }] },
          "Post URL": { url: `${apiBase}/posts/${post.id}` },
          Error: { rich_text: [] }, // clear a stale error from a prior failed attempt
        } as never,
      });
      await notion.pages.update({
        page_id: page.id,
        properties: {
          // status options must pre-exist in Notion; select options auto-create
          Status: kind === "status" ? { status: { name: "Done" } } : { select: { name: "Done" } },
        } as never,
      });
    } catch (err) {
      // The remote post may already exist (creation succeeded, a write below failed,
      // e.g. transient 429/network) — persist its id so the continue guard above
      // stops the next run from re-posting and creating a duplicate.
      await notion.pages.update({
        page_id: page.id,
        properties: {
          ...(post?.id
            ? { "Post ID": { rich_text: [{ type: "text", text: { content: String(post.id) } }] } }
            : {}),
          // surface on the row (rich text caps at 2000 chars), don't swallow
          Error: { rich_text: [{ type: "text", text: { content: String(err).slice(0, 1900) } }] },
        } as never,
      });
    }
  }
}

async function postToApi(base: string, path: string, key: string, body: unknown) {
  const res = await fetch(base + path, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`); // surface, don't swallow
  return res.json();
}
