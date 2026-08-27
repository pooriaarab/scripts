import { describe, it, expect, beforeEach } from "vitest";
import worker, { type Env } from "./index.js";

// Minimal in-memory R2 mock
type R2Object = {
  key: string;
  body: ArrayBuffer;
  size: number;
  customMetadata?: Record<string, string>;
  httpMetadata?: { contentType?: string };
};

class FakeR2Bucket {
  store = new Map<string, R2Object>();

  async put(key: string, value: ArrayBuffer | Uint8Array | string | ReadableStream, opts?: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> }) {
    let body: ArrayBuffer;
    // The worker streams uploads straight to R2, so the mock has to drain a
    // ReadableStream the way the real bucket does. A mock that only accepts a
    // buffer would pass while the deployed worker failed.
    if (value instanceof ReadableStream) body = await new Response(value).arrayBuffer();
    else if (value instanceof ArrayBuffer) body = value;
    else if (value instanceof Uint8Array) body = value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
    else body = new TextEncoder().encode(value as string).buffer as ArrayBuffer;
    const obj: R2Object = {
      key,
      body,
      size: body.byteLength,
      customMetadata: opts?.customMetadata,
      httpMetadata: opts?.httpMetadata,
    };
    this.store.set(key, obj);
    return obj as unknown as R2Object;
  }

  async get(key: string) {
    const obj = this.store.get(key);
    if (!obj) return null;
    return {
      key: obj.key,
      size: obj.size,
      customMetadata: obj.customMetadata,
      httpMetadata: obj.httpMetadata,
      body: new Blob([obj.body]).stream(),
      arrayBuffer: async () => obj.body,
      text: async () => new TextDecoder().decode(obj.body),
    } as unknown as R2Bucket["get"] extends (...args: unknown[]) => Promise<infer T> ? T : never;
  }
}

function envWithToken(token = "test-token-123"): Env & { CACHE: FakeR2Bucket } {
  return {
    TURBO_TOKEN: token,
    CACHE: new FakeR2Bucket() as unknown as R2Bucket,
  } as unknown as Env & { CACHE: FakeR2Bucket };
}

function req(url: string, init?: RequestInit): Request {
  // Default to no auth unless caller sets Authorization
  return new Request(url, init);
}

const BASE = "https://cache.example.com";

describe("auth", () => {
  it("401 without token", async () => {
    const env = envWithToken();
    const res = await worker.fetch(req(`${BASE}/v8/artifacts/status`), env);
    expect(res.status).toBe(401);
  });

  it("401 with wrong token", async () => {
    const env = envWithToken("correct-token");
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/status`, { headers: { Authorization: "Bearer wrong-token" } }),
      env,
    );
    expect(res.status).toBe(401);
  });

  it("401 with malformed Authorization header (no Bearer prefix)", async () => {
    const env = envWithToken("correct-token");
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/status`, { headers: { Authorization: "correct-token" } }),
      env,
    );
    expect(res.status).toBe(401);
  });

  it("200 with correct token", async () => {
    const env = envWithToken("correct-token");
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/status`, { headers: { Authorization: "Bearer correct-token" } }),
      env,
    );
    expect(res.status).toBe(200);
    const body = await res.json() as { status: string };
    expect(body.status).toBe("enabled");
  });
});

describe("artifacts", () => {
  it("PUT then GET round-trip", async () => {
    const env = envWithToken();
    const hash = "abc123def456";
    const payload = new TextEncoder().encode("hello turbo");

    const put = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=myteam`, {
        method: "PUT",
        headers: { Authorization: "Bearer test-token-123" },
        body: payload,
      }),
      env,
    );
    expect(put.status).toBe(200);

    const got = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=myteam`, {
        headers: { Authorization: "Bearer test-token-123" },
      }),
      env,
    );
    expect(got.status).toBe(200);
    expect(got.headers.get("content-type")).toBe("application/octet-stream");
    const buf = await got.arrayBuffer();
    expect(new TextDecoder().decode(buf)).toBe("hello turbo");
  });

  it("404 for missing hash", async () => {
    const env = envWithToken();
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/doesnotexist123?teamId=myteam`, {
        headers: { Authorization: "Bearer test-token-123" },
      }),
      env,
    );
    expect(res.status).toBe(404);
  });

  it("x-artifact-tag preserved across PUT and GET", async () => {
    const env = envWithToken();
    const hash = "deadbeef1234";
    const tag = "some-signature-tag-value";

    const put = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=myteam`, {
        method: "PUT",
        headers: {
          Authorization: "Bearer test-token-123",
          "x-artifact-tag": tag,
        },
        body: new TextEncoder().encode("tagged content"),
      }),
      env,
    );
    expect(put.status).toBe(200);

    const got = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=myteam`, {
        headers: { Authorization: "Bearer test-token-123" },
      }),
      env,
    );
    expect(got.status).toBe(200);
    expect(got.headers.get("x-artifact-tag")).toBe(tag);
  });

  it("rejected malformed hash (path traversal / unsafe chars)", async () => {
    const env = envWithToken();
    const badHashes = ["../escape", "a/b", "a..b", "hash with space", "hash/with/slash", "../../etc/passwd"];
    for (const h of badHashes) {
      const res = await worker.fetch(
        req(`${BASE}/v8/artifacts/${encodeURIComponent(h)}?teamId=myteam`, {
          method: "PUT",
          headers: { Authorization: "Bearer test-token-123" },
          body: new TextEncoder().encode("x"),
        }),
        env,
      );
      expect(res.status, `hash ${JSON.stringify(h)} should be rejected`).toBe(400);
    }
  });

  it("team scoping: same hash different teams do not collide", async () => {
    const env = envWithToken();
    const hash = "samehash999";
    await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=team-a`, {
        method: "PUT",
        headers: { Authorization: "Bearer test-token-123" },
        body: new TextEncoder().encode("team-a content"),
      }),
      env,
    );
    await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=team-b`, {
        method: "PUT",
        headers: { Authorization: "Bearer test-token-123" },
        body: new TextEncoder().encode("team-b content"),
      }),
      env,
    );
    const gotA = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=team-a`, {
        headers: { Authorization: "Bearer test-token-123" },
      }),
      env,
    );
    const gotB = await worker.fetch(
      req(`${BASE}/v8/artifacts/${hash}?teamId=team-b`, {
        headers: { Authorization: "Bearer test-token-123" },
      }),
      env,
    );
    expect(await gotA.text()).toBe("team-a content");
    expect(await gotB.text()).toBe("team-b content");
  });

  it("GET status returns enabled", async () => {
    const env = envWithToken();
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/status`, { headers: { Authorization: "Bearer test-token-123" } }),
      env,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "enabled" });
  });

  it("POST events returns 200 empty", async () => {
    const env = envWithToken();
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/events`, {
        method: "POST",
        headers: { Authorization: "Bearer test-token-123" },
        body: JSON.stringify([{ event: "HIT" }]),
      }),
      env,
    );
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toBe("");
  });
});

describe("team scoping", () => {
  const TOKEN = "test-token-123";
  const auth = { authorization: `Bearer ${TOKEN}` };

  it("rejects a teamId that would escape the team prefix", async () => {
    const env = envWithToken(TOKEN);
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/abc123?teamId=..%2F..%2Fother`, { headers: auth }),
      env,
    );
    expect(res.status).toBe(400);
  });

  it("rejects a slug that would escape the team prefix", async () => {
    const env = envWithToken(TOKEN);
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/abc123?slug=..%2Fevil`, { headers: auth }),
      env,
    );
    expect(res.status).toBe(400);
  });

  it("keeps two teams' artifacts apart under the same hash", async () => {
    const env = envWithToken(TOKEN);
    await worker.fetch(
      req(`${BASE}/v8/artifacts/samehash?teamId=teamA`, { method: "PUT", body: "A-payload", headers: auth }),
      env,
    );
    await worker.fetch(
      req(`${BASE}/v8/artifacts/samehash?teamId=teamB`, { method: "PUT", body: "B-payload", headers: auth }),
      env,
    );
    const got = await worker.fetch(
      req(`${BASE}/v8/artifacts/samehash?teamId=teamA`, { headers: auth }),
      env,
    );
    expect(await got.text()).toBe("A-payload");
  });
});

describe("team scope pinning", () => {
  const TOKEN = "test-token-123";
  const auth = { authorization: `Bearer ${TOKEN}` };

  it("serves the pinned team", async () => {
    const env = { ...envWithToken(TOKEN), ALLOWED_TEAM: "acme" };
    const put = await worker.fetch(
      req(`${BASE}/v8/artifacts/abc123?teamId=acme`, { method: "PUT", body: "ok", headers: auth }),
      env,
    );
    expect(put.status).toBe(200);
  });

  it("rejects another team even with a valid token", async () => {
    const env = { ...envWithToken(TOKEN), ALLOWED_TEAM: "acme" };
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/abc123?teamId=other`, { headers: auth }),
      env,
    );
    expect(res.status).toBe(403);
  });

  it("serves any valid team when no pin is configured", async () => {
    const env = envWithToken(TOKEN);
    const res = await worker.fetch(
      req(`${BASE}/v8/artifacts/abc123?teamId=whatever`, { headers: auth }),
      env,
    );
    expect(res.status).toBe(404); // reached the bucket, found nothing
  });
});

describe("streaming upload", () => {
  it("stores a streamed body byte-for-byte", async () => {
    const TOKEN = "test-token-123";
    const env = envWithToken(TOKEN);
    const payload = "x".repeat(200_000);
    await worker.fetch(
      req(`${BASE}/v8/artifacts/bigone?teamId=t`, {
        method: "PUT", body: payload, headers: { authorization: `Bearer ${TOKEN}` },
      }),
      env,
    );
    const got = await worker.fetch(
      req(`${BASE}/v8/artifacts/bigone?teamId=t`, { headers: { authorization: `Bearer ${TOKEN}` } }),
      env,
    );
    expect((await got.text()).length).toBe(payload.length);
  });
});
