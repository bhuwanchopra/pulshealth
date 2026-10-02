import { describe, expect, it } from "vitest";

import { MAP_STYLES } from "./mapStyles";
import { contentSecurityPolicy, newNonce, STATIC_SECURITY_HEADERS, tileImageSources } from "./securityHeaders";

describe("content security policy", () => {
  it("allows scripts only by nonce, eval only in development", () => {
    const nonce = newNonce();
    const csp = contentSecurityPolicy(nonce, false);
    const script = csp.split("; ").find((d) => d.startsWith("script-src"))!;
    expect(script).toBe(`script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`);
    expect(csp).not.toContain("unsafe-eval");
    expect(contentSecurityPolicy(nonce, true)).toContain("'unsafe-eval'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("object-src 'none'");
    expect(csp).toContain("form-action 'self'");
    expect(csp).not.toContain("upgrade-insecure-requests"); // would break a plain-HTTP LAN install
  });

  it("makes a fresh nonce each time", () => {
    expect(newNonce()).not.toBe(newNonce());
    expect(atob(newNonce())).toHaveLength(16);
  });

  it("allows every basemap's tile host, so a new style cannot be blocked", () => {
    const sources = tileImageSources();
    for (const style of MAP_STYLES) {
      if (!style.spec) continue;
      const host = new URL(style.spec.url.replace("{s}", "a")).host;
      const allowed = sources.some((s) => {
        const pattern = new URL(s.replace("*", "wildcard")).host.replace("wildcard", "");
        return s.includes("*") ? host.endsWith(pattern) : host === pattern;
      });
      expect(allowed, style.id).toBe(true);
    }
    const img = contentSecurityPolicy("n", false).split("; ").find((d) => d.startsWith("img-src"))!;
    for (const source of sources) expect(img).toContain(source);
  });

  it("sets the static headers the plan calls for", () => {
    const keys = Object.fromEntries(STATIC_SECURITY_HEADERS.map((h) => [h.key, h.value]));
    expect(keys["Referrer-Policy"]).toBe("same-origin");
    expect(keys["X-Content-Type-Options"]).toBe("nosniff");
    expect(keys["Strict-Transport-Security"]).toMatch(/^max-age=\d+$/);
    expect(keys["X-Frame-Options"]).toBe("DENY");
  });
});
