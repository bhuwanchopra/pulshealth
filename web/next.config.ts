import type { NextConfig } from "next";

import { STATIC_SECURITY_HEADERS } from "./lib/securityHeaders";

const nextConfig: NextConfig = {
  // Emit a self-contained server bundle (.next/standalone) for the Docker image.
  output: "standalone",
  // pg is a server-only dependency; keep it external to the bundle.
  serverExternalPackages: ["pg"],
  // Every response, every mode. The Content-Security-Policy is per request
  // (it carries a nonce), so proxy.ts sets that one.
  async headers() {
    return [{ source: "/:path*", headers: STATIC_SECURITY_HEADERS }];
  },
  // No "X-Powered-By: Next.js".
  poweredByHeader: false,
};

export default nextConfig;
