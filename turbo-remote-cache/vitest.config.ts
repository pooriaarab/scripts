import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // No Workers pool needed — tests use an in-memory R2 mock.
    // Keeping this explicit avoids pulling in @cloudflare/vitest-pool-workers
    // for the default unit run. Integration with real workerd can be added later.
    include: ["src/**/*.test.ts"],
  },
});
