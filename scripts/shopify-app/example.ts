// Smallest real Shopify-app wiring: shopifyApp() server config + one webhook route.
// The webhook authenticates (HMAC), calls your product's REST API best-effort, and always 200s.

// --- app/shopify.server.ts ---
import "@shopify/shopify-app-remix/adapters/node";
import {
  ApiVersion,
  AppDistribution,
  shopifyApp,
} from "@shopify/shopify-app-remix/server";
import { SQLiteSessionStorage } from "@shopify/shopify-app-session-storage-sqlite"; // dev only; use a DB-backed store in prod

const shopify = shopifyApp({
  apiKey: process.env.SHOPIFY_API_KEY,
  apiSecretKey: process.env.SHOPIFY_API_SECRET || "",
  apiVersion: ApiVersion.January25,
  scopes: process.env.SCOPES?.split(","),
  appUrl: process.env.SHOPIFY_APP_URL || "",
  authPathPrefix: "/auth", // redirect_urls in shopify.app.toml must cover these callbacks
  sessionStorage: new SQLiteSessionStorage("shopify_sessions.sqlite"),
  distribution: AppDistribution.AppStore,
});

export const authenticate = shopify.authenticate;

// --- app/routes/webhooks.products.tsx ---
import type { ActionFunctionArgs } from "@remix-run/node";

export const action = async ({ request }: ActionFunctionArgs) => {
  // HMAC verification happens here; a bad signature never reaches your code.
  const { shop, topic, payload } = await authenticate.webhook(request);

  try {
    // Load this shop's saved settings (their API key for YOUR product), then call
    // your product's SDK / public REST API. Swap this block for your real handler.
    const product = payload as { title?: string };
    console.log(`[${topic}] ${shop}: ${product?.title}`);
    // await yourApi.draftSomething(apiKeyForShop(shop), { ... });
  } catch (error) {
    // Shopify retries non-2xx deliveries — your downstream outage must NOT propagate.
    console.error("webhook handler failed; still returning 200:", error);
  }

  return new Response(); // always 200 once authenticated
};
