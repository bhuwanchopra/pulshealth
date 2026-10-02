import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// The `@/` import alias from tsconfig.json, so tests can load proxy.ts and the
// route handlers the way Next.js does.
export default defineConfig({
  resolve: {
    alias: { "@": fileURLToPath(new URL(".", import.meta.url)) },
  },
});
