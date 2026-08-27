/**
 * Turborepo Remote Cache — Cloudflare Worker + R2
 *
 * Implements the 4 endpoints Turborepo expects:
 *   GET  /v8/artifacts/:hash
 *   PUT  /v8/artifacts/:hash
 *   POST /v8/artifacts/events
 *   GET  /v8/artifacts/status
 *
 * Env:
 *   TURBO_TOKEN — bearer token Turborepo sends as `Authorization: Bearer <token>`
 *   CACHE       — R2 bucket binding
 */

export interface Env {
  TURBO_TOKEN: string;
  CACHE: R2Bucket;
  /**
   * Optional. When set, only this exact team scope is served, and any other
   * `teamId`/`slug` is rejected with 403.
   *
   * Without it the token is the ONLY credential: it is shared, and every
   * syntactically valid team scope is reachable by anyone holding it. That is
   * fine when one trust boundary shares one token, and wrong the moment two do.
   * Setting it makes the isolation real rather than implied.
   */
  ALLOWED_TEAM?: string;
}

// Hash must be a safe R2 key segment. Allow hex / base64url-ish identifiers.
// At least one char, at most 256, only alphanumerics, hyphen, underscore.
// This rejects `.`, `/`, `\`, `..`, null bytes, etc.
const HASH_RE = /^[A-Za-z0-9_-]{1,256}$/;

// Compare two strings in constant time relative to content. Length still
// leaks, which is acceptable: all real tokens are the same length.
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const aBytes = enc.encode(a);
  const bBytes = enc.encode(b);
  if (aBytes.length !== bBytes.length) return false;
  let out = 0;
  for (let i = 0; i < aBytes.length; i++) {
    out |= aBytes[i] ^ bBytes[i]!;
  }
  return out === 0;
}

function getAuthToken(request: Request): string | null {
  const header = request.headers.get("authorization") || request.headers.get("Authorization");
  if (!header) return null;
  // Must be exactly `Bearer <token>` — case-sensitive "Bearer", single space.
  if (!header.startsWith("Bearer ")) return null;
  return header.slice(7);
}

function isAuthorized(request: Request, env: Env): boolean {
  const token = getAuthToken(request);
  if (token === null) return false;
  // env.TURBO_TOKEN is a secret binding; never hardcode.
  const expected = env.TURBO_TOKEN;
  if (!expected) return false;
  return timingSafeEqual(token, expected);
}

// teamId and slug are caller-controlled and go straight into the R2 key, so
// they need the same validation the hash gets. Without it `?teamId=../../x`
// walks out of the team's prefix and reads another team's artifacts, which
// defeats the only isolation this cache has.
const TEAM_RE = /^[A-Za-z0-9_-]{1,128}$/;

function teamSegment(url: URL): string | null {
  const teamId = url.searchParams.get("teamId") ?? url.searchParams.get("team") ?? "";
  const slug = url.searchParams.get("slug") ?? "";
  if (teamId && !TEAM_RE.test(teamId)) return null;
  if (slug && !TEAM_RE.test(slug)) return null;
  if (teamId && slug) return `${teamId}/${slug}`;
  if (teamId) return teamId;
  if (slug) return slug;
  return "default";
}

type KeyResult = { key: string } | { error: "team"; status: 400 | 403 };

function r2Key(url: URL, hash: string, env: Env): KeyResult {
  const team = teamSegment(url);
  if (team === null) return { error: "team", status: 400 };
  // A valid token must not reach another team's artifacts. Pin the worker to
  // one scope when the deployment only serves one.
  if (env.ALLOWED_TEAM && team !== env.ALLOWED_TEAM) return { error: "team", status: 403 };
  return { key: `${team}/${hash}` };
}

function json(data: unknown, init?: ResponseInit): Response {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(init?.headers as Record<string, string> | undefined),
    },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const method = request.method.toUpperCase();
    const pathname = url.pathname;

    // --- Auth gate: every request needs Bearer token ---
    if (!isAuthorized(request, env)) {
      return json({ error: "Unauthorized" }, { status: 401 });
    }

    // GET /v8/artifacts/status
    if (method === "GET" && pathname === "/v8/artifacts/status") {
      return json({ status: "enabled" }, { status: 200 });
    }

    // POST /v8/artifacts/events — telemetry, always 200 empty
    if (method === "POST" && pathname === "/v8/artifacts/events") {
      // Drain body if present so the connection can be reused; ignore content.
      // Not required but avoids potential stream issues on some runtimes.
      try {
        await request.arrayBuffer();
      } catch {
        // ignore
      }
      return new Response("", { status: 200 });
    }

    // GET / PUT / HEAD /v8/artifacts/:hash
    // Turborepo also issues HEAD for existence checks in some versions;
    // handle it the same as GET without a body.
    const artifactMatch = pathname.match(/^\/v8\/artifacts\/([^/]+)$/);
    if (artifactMatch) {
      const hash = decodeURIComponent(artifactMatch[1]!);

      if (!HASH_RE.test(hash)) {
        return json({ error: "Invalid hash" }, { status: 400 });
      }

      const scoped = r2Key(url, hash, env);
      if ("error" in scoped) {
        return json(
          { error: scoped.status === 403 ? "Team not served by this cache" : "Invalid team" },
          { status: scoped.status },
        );
      }
      const key = scoped.key;

      if (method === "PUT") {
        const tag = request.headers.get("x-artifact-tag") ?? request.headers.get("X-Artifact-Tag") ?? undefined;

        const customMetadata: Record<string, string> | undefined = tag ? { "x-artifact-tag": tag } : undefined;

        // Stream straight to R2. Buffering with arrayBuffer() held the whole
        // artifact in memory, and a Workers isolate shares roughly 128 MB
        // across every request in flight -- a few concurrent uploads of a large
        // cache entry is enough to reach that ceiling.
        const body = request.body ?? new ArrayBuffer(0);
        await env.CACHE.put(key, body as ReadableStream | ArrayBuffer, {
          httpMetadata: { contentType: "application/octet-stream" },
          customMetadata,
        });

        // Turborepo expects 200 (or 202) on successful upload.
        return json({ urls: [hash] }, { status: 200 });
      }

      if (method === "GET" || method === "HEAD") {
        const obj = await env.CACHE.get(key);
        if (!obj) {
          return json({ error: "Not found" }, { status: 404 });
        }

        const headers = new Headers();
        headers.set("content-type", "application/octet-stream");
        // httpMetadata from R2 may already include content-type; ensure ours wins.
        const tag = obj.customMetadata?.["x-artifact-tag"];
        if (tag) headers.set("x-artifact-tag", tag);
        // Also echo content-length if available
        if (obj.size !== undefined) headers.set("content-length", String(obj.size));

        if (method === "HEAD") {
          return new Response(null, { status: 200, headers });
        }

        // obj.body is a ReadableStream; return it directly
        return new Response(obj.body as ReadableStream, { status: 200, headers });
      }
    }

    return json({ error: "Not found" }, { status: 404 });
  },
};
